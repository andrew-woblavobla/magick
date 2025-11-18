# frozen_string_literal: true

module Magick
  module Adapters
    class Registry
    def initialize(memory_adapter, redis_adapter = nil, circuit_breaker: nil, async: false)
      @memory_adapter = memory_adapter
      @redis_adapter = redis_adapter
      @circuit_breaker = circuit_breaker || Magick::CircuitBreaker.new
      @async = async
    end

      def get(feature_name, key)
        # Try memory first (fastest)
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
        redis_adapter&.delete(feature_name)
      rescue AdapterError
        # Continue even if Redis fails
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
    end
  end
end
