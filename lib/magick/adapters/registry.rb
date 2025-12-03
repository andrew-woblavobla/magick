# frozen_string_literal: true

module Magick
  module Adapters
    class Registry
      CACHE_INVALIDATION_CHANNEL = 'magick:cache:invalidate'

      def initialize(memory_adapter, redis_adapter = nil, active_record_adapter: nil, circuit_breaker: nil,
                     async: false, primary: nil)
        @memory_adapter = memory_adapter
        @redis_adapter = redis_adapter
        @active_record_adapter = active_record_adapter
        @circuit_breaker = circuit_breaker || Magick::CircuitBreaker.new
        @async = async
        @primary = primary || :memory # :memory, :redis, or :active_record
        @subscriber_thread = nil
        @subscriber = nil
        @last_reload_times = {} # Track last reload time per feature for debouncing
        @reload_mutex = Mutex.new
        # Only start Pub/Sub subscriber if Redis is available
        # In memory-only mode, each process has isolated cache (no cross-process invalidation)
        start_cache_invalidation_subscriber if redis_adapter
      end

      def get(feature_name, key)
        # Try memory first (fastest) - no Redis calls needed thanks to Pub/Sub invalidation
        value = memory_adapter.get(feature_name, key) if memory_adapter
        return value unless value.nil?

        # Fall back to Redis if available
        if redis_adapter
          begin
            value = redis_adapter.get(feature_name, key)
            # Update memory cache if found in Redis
            if value && memory_adapter
              memory_adapter.set(feature_name, key, value)
              return value
            end
            # If Redis returns nil, continue to next adapter
          rescue StandardError, AdapterError
            # Redis failed, continue to next adapter
          end
        end

        # Fall back to Active Record if available
        if active_record_adapter
          begin
            value = active_record_adapter.get(feature_name, key)
            # Update memory cache if found in Active Record
            memory_adapter.set(feature_name, key, value) if value && memory_adapter
            return value
          rescue StandardError, AdapterError
            # Active Record failed, return nil
            nil
          end
        end

        nil
      end

      def set(feature_name, key, value)
        # Update memory first (always synchronous)
        memory_adapter&.set(feature_name, key, value)

        # Update Redis if available
        if redis_adapter
          update_redis = proc do
            circuit_breaker.call do
              redis_adapter.set(feature_name, key, value)
            end
          rescue AdapterError => e
            # Log error but don't fail - memory is updated
            warn "Failed to update Redis: #{e.message}" if defined?(Rails) && Rails.env.development?
          end

          if @async && defined?(Thread)
            # For async updates, publish cache invalidation synchronously
            # This ensures other processes are notified immediately, even if Redis update is delayed
            publish_cache_invalidation(feature_name)
            Thread.new { update_redis.call }
          else
            update_redis.call
            # Publish cache invalidation message to notify other processes
            publish_cache_invalidation(feature_name)
          end
        end

        # Always update Active Record if available (as fallback/persistence layer)
        return unless active_record_adapter

        begin
          active_record_adapter.set(feature_name, key, value)
        rescue AdapterError => e
          # Log error but don't fail
          warn "Failed to update Active Record: #{e.message}" if defined?(Rails) && Rails.env.development?
        end
      end

      def delete(feature_name)
        memory_adapter&.delete(feature_name)

        if redis_adapter
          begin
            redis_adapter.delete(feature_name)
            # Publish cache invalidation message
            publish_cache_invalidation(feature_name)
          rescue AdapterError
            # Continue even if Redis fails
          end
        end

        return unless active_record_adapter

        begin
          active_record_adapter.delete(feature_name)
        rescue AdapterError
          # Continue even if Active Record fails
        end
      end

      def exists?(feature_name)
        return true if memory_adapter&.exists?(feature_name)
        return true if redis_adapter&.exists?(feature_name) == true
        return true if active_record_adapter&.exists?(feature_name) == true

        false
      end

      def all_features
        features = []
        features += memory_adapter.all_features if memory_adapter
        features += redis_adapter.all_features if redis_adapter
        features += active_record_adapter.all_features if active_record_adapter
        features.uniq
      end

      # Explicitly trigger cache invalidation for a feature
      # This is useful for targeting updates that need immediate cache invalidation
      # Invalidates memory cache in current process AND publishes to Redis for other processes
      def invalidate_cache(feature_name)
        # Invalidate memory cache in current process immediately
        memory_adapter&.delete(feature_name)

        # Publish to Redis Pub/Sub to invalidate cache in other processes
        publish_cache_invalidation(feature_name)
      end

      # Check if Redis adapter is available
      def redis_available?
        !redis_adapter.nil?
      end

      # Get Redis client (public method for use by other classes)
      def redis_client
        return nil unless redis_adapter

        redis_adapter.instance_variable_get(:@redis)
      end

      # Publish cache invalidation message to Redis Pub/Sub (without deleting local memory cache)
      # This is useful when you've just updated the cache and want to notify other processes
      # but keep the local memory cache intact
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

      private

      attr_reader :memory_adapter, :redis_adapter, :active_record_adapter, :circuit_breaker

      # Start a background thread to listen for cache invalidation messages
      def start_cache_invalidation_subscriber
        return unless redis_adapter && defined?(Thread)

        @subscriber_thread = Thread.new do
          redis_client = redis_adapter.instance_variable_get(:@redis)
          return unless redis_client

          @subscriber = redis_client.dup
          @subscriber.subscribe(CACHE_INVALIDATION_CHANNEL) do |on|
            on.message do |_channel, feature_name|
              feature_name_str = feature_name.to_s

              # Debounce: only reload if we haven't reloaded this feature in the last 100ms
              # This prevents duplicate reloads from multiple invalidation messages
              should_reload = @reload_mutex.synchronize do
                last_reload = @last_reload_times[feature_name_str]
                now = Time.now.to_f
                if last_reload.nil? || (now - last_reload) > 0.1 # 100ms debounce
                  @last_reload_times[feature_name_str] = now
                  true
                else
                  false
                end
              end

              next unless should_reload

              # Invalidate memory cache for this feature
              memory_adapter.delete(feature_name_str) if memory_adapter

              # Also reload the feature instance in Magick.features if it exists
              # This ensures the feature instance has the latest targeting and values
              if defined?(Magick) && Magick.features.key?(feature_name_str)
                feature = Magick.features[feature_name_str]
                if feature.respond_to?(:reload)
                  feature.reload
                  # Log for debugging (only in development, and only once per debounce period)
                  if defined?(Rails) && Rails.env.development?
                    Rails.logger.debug "Magick: Reloaded feature '#{feature_name_str}' after cache invalidation"
                  end
                end
              end
            rescue StandardError => e
              # Log error but don't crash the subscriber thread
              if defined?(Rails) && Rails.env.development?
                warn "Magick: Error processing cache invalidation for '#{feature_name}': #{e.message}"
              end
            end
          end
        rescue StandardError => e
          # If subscription fails, log and retry after a delay
          warn "Cache invalidation subscriber error: #{e.message}" if defined?(Rails) && Rails.env.development?
          sleep 5
          retry
        end
        @subscriber_thread.abort_on_exception = false
      end
    end
  end
end
