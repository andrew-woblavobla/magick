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
        # Skip version checks for the version key itself to avoid infinite loops
        if key.to_s == '_version'
          value = memory_adapter.get(feature_name, key)
          return value unless value.nil?
          return redis_adapter&.get(feature_name, key) if redis_adapter
          return nil
        end

        # Try memory first (fastest)
        value = memory_adapter.get(feature_name, key)

        # If we have a value in memory and Redis is available, check version to ensure cache is fresh
        if !value.nil? && redis_adapter
          begin
            # Check if Redis has a newer version (only check if we have memory cache)
            redis_version = redis_adapter.get(feature_name, '_version')
            memory_version = memory_adapter.get(feature_name, '_version')

            # If Redis version is newer or memory version is nil, invalidate cache
            if redis_version && (memory_version.nil? || redis_version > memory_version)
              # Invalidate memory cache for this feature (forces reload from Redis)
              memory_adapter.delete(feature_name)
              # Now get from Redis (which will cache back to memory)
              value = redis_adapter.get(feature_name, key)
              if value
                memory_adapter.set(feature_name, key, value)
                memory_adapter.set(feature_name, '_version', redis_version)
              end
              return value
            end
          rescue AdapterError
            # Redis failed, use cached value
          end
        end

        return value unless value.nil?

        # Fall back to Redis if available
        if redis_adapter
          begin
            value = redis_adapter.get(feature_name, key)
            # Update memory cache if found in Redis
            if value
              memory_adapter.set(feature_name, key, value)
              # Also store version from Redis
              redis_version = redis_adapter.get(feature_name, '_version')
              memory_adapter.set(feature_name, '_version', redis_version) if redis_version
            end
            return value
          rescue AdapterError
            # Redis failed, return nil
            nil
          end
        end

        nil
      end

      def set(feature_name, key, value)
        # Skip version key updates from triggering version updates
        return if key.to_s == '_version'

        # Generate new version timestamp
        new_version = Time.now.to_f

        # Update memory first (always synchronous)
        memory_adapter.set(feature_name, key, value)
        memory_adapter.set(feature_name, '_version', new_version)

        # Update Redis if available
        if redis_adapter
          update_redis = proc do
            circuit_breaker.call do
              redis_adapter.set(feature_name, key, value)
              redis_adapter.set(feature_name, '_version', new_version)
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
