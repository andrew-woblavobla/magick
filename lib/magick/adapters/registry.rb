# frozen_string_literal: true

module Magick
  module Adapters
    class Registry
      CACHE_INVALIDATION_CHANNEL = 'magick:cache:invalidate'.freeze

      def initialize(memory_adapter, redis_adapter = nil, circuit_breaker: nil, async: false)
        @memory_adapter = memory_adapter
        @redis_adapter = redis_adapter
        @circuit_breaker = circuit_breaker || Magick::CircuitBreaker.new
        @async = async
        @subscriber_thread = nil
        @subscriber = nil
        # Only start Pub/Sub subscriber if Redis is available
        # In memory-only mode, each process has isolated cache (no cross-process invalidation)
        start_cache_invalidation_subscriber if redis_adapter
      end

      def get(feature_name, key)
        # Try memory first (fastest) - no Redis calls needed thanks to Pub/Sub invalidation
        value = memory_adapter.get(feature_name, key)
        return value unless value.nil?

        # Fall back to Redis if available
        if redis_adapter
          begin
            value = redis_adapter.get(feature_name, key)
            # Update memory cache if found in Redis
            memory_adapter.set(feature_name, key, value) if value
            return value
          rescue AdapterError
            # Redis failed, return nil
            nil
          end
        end

        nil
      end

      def set(feature_name, key, value)
        # Update memory first (always synchronous)
        memory_adapter.set(feature_name, key, value)

        # Update Redis if available
        if redis_adapter
          update_redis = proc do
            circuit_breaker.call do
              redis_adapter.set(feature_name, key, value)
              # Publish cache invalidation message to notify other processes
              publish_cache_invalidation(feature_name)
            end
          rescue AdapterError => e
            # Log error but don't fail - memory is updated
            warn "Failed to update Redis: #{e.message}" if defined?(Rails) && Rails.env.development?
          end

          if @async && defined?(Thread)
            Thread.new { update_redis.call }
          else
            update_redis.call
          end
        end
      end

      def delete(feature_name)
        memory_adapter.delete(feature_name)
        if redis_adapter
          begin
            redis_adapter.delete(feature_name)
            # Publish cache invalidation message
            publish_cache_invalidation(feature_name)
          rescue AdapterError
            # Continue even if Redis fails
          end
        end
      end

      def exists?(feature_name)
        memory_adapter.exists?(feature_name) || (redis_adapter&.exists?(feature_name) == true)
      end

      def all_features
        memory_features = memory_adapter.all_features
        redis_features = redis_adapter&.all_features || []
        (memory_features + redis_features).uniq
      end

      private

      attr_reader :memory_adapter, :redis_adapter, :circuit_breaker

      # Publish cache invalidation message to Redis Pub/Sub
      def publish_cache_invalidation(feature_name)
        return unless redis_adapter

        begin
          redis_client = redis_adapter.instance_variable_get(:@redis)
          redis_client&.publish(CACHE_INVALIDATION_CHANNEL, feature_name.to_s)
        rescue StandardError => e
          # Silently fail - cache invalidation is best effort
          warn "Failed to publish cache invalidation: #{e.message}" if defined?(Rails) && Rails.env.development?
        end
      end

      # Start a background thread to listen for cache invalidation messages
      def start_cache_invalidation_subscriber
        return unless redis_adapter && defined?(Thread)

        @subscriber_thread = Thread.new do
          begin
            redis_client = redis_adapter.instance_variable_get(:@redis)
            return unless redis_client

            @subscriber = redis_client.dup
            @subscriber.subscribe(CACHE_INVALIDATION_CHANNEL) do |on|
              on.message do |_channel, feature_name|
                # Invalidate memory cache for this feature
                memory_adapter.delete(feature_name)
              end
            end
          rescue StandardError => e
            # If subscription fails, log and retry after a delay
            warn "Cache invalidation subscriber error: #{e.message}" if defined?(Rails) && Rails.env.development?
            sleep 5
            retry
          end
        end
        @subscriber_thread.abort_on_exception = false
      end
    end
  end
end
