# frozen_string_literal: true

module Magick
  module Adapters
    class Registry
      CACHE_INVALIDATION_CHANNEL = 'magick:cache:invalidate'

      LOCAL_WRITE_TTL = 2.0 # seconds to ignore self-invalidation after a local write

      # Accept only conservative feature identifiers coming off the wire.
      # Anything outside this alphabet (newlines, spaces, Unicode punctuation,
      # 200-char garbage) is a sign of a malformed or malicious publisher and
      # must not be fed back into Magick.features[...] / feature.reload.
      FEATURE_NAME_PATTERN = /\A[a-zA-Z0-9_\-.:]{1,120}\z/.freeze

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
        @refresh_thread = nil
        @last_reload_times = {} # Track last reload time per feature for debouncing
        @local_writes = {} # Track recent local writes to skip self-invalidation
        @reload_mutex = Mutex.new
        @stopping = false
        @shutdown_mutex = Mutex.new
        @owner_pid = Process.pid
        # Only start Pub/Sub subscriber if Redis is available
        # In memory-only mode, each process has isolated cache (no cross-process invalidation)
        start_cache_invalidation_subscriber if redis_adapter
      end

      # Restart the Pub/Sub subscriber after a fork. The subscriber thread is
      # not carried into child processes, so a worker inheriting a stale
      # reference must re-create its own subscription. Safe to call on every
      # request; it only does work when Process.pid changes.
      def ensure_subscriber!
        return if @owner_pid == Process.pid

        @shutdown_mutex.synchronize do
          return if @owner_pid == Process.pid

          @subscriber_thread = nil
          @subscriber = nil
          @owner_pid = Process.pid
          @stopping = false
        end

        start_cache_invalidation_subscriber if redis_adapter
      end

      # Gracefully terminate the Pub/Sub subscriber thread and its Redis connection.
      # Without this, Ruby/Puma shutdown waits on the blocking `subscribe` call.
      def shutdown(timeout: 5)
        @shutdown_mutex.synchronize do
          return if @stopping

          @stopping = true
        end

        close_subscriber_connection(@subscriber)
        terminate_subscriber_thread(@subscriber_thread, timeout)

        @subscriber = nil
        @subscriber_thread = nil
        true
      end

      def stopping?
        @stopping == true
      end

      def get(feature_name, key)
        # Try memory first (fastest) - no Redis calls needed thanks to Pub/Sub invalidation
        value = memory_adapter.get(feature_name, key) if memory_adapter
        return value unless value.nil?

        # Fall back to Redis if available
        if redis_adapter
          begin
            value = redis_adapter.get(feature_name, key)
            if !value.nil? && memory_adapter
              memory_adapter.set(feature_name, key, value)
              return value
            end
          rescue StandardError, AdapterError
            # Redis failed, continue to next adapter
          end
        end

        # Fall back to Active Record if available
        if active_record_adapter
          begin
            value = active_record_adapter.get(feature_name, key)
            memory_adapter.set(feature_name, key, value) if !value.nil? && memory_adapter
            return value
          rescue StandardError, AdapterError
            nil
          end
        end

        nil
      end

      def set(feature_name, key, value)
        # Update memory first (always synchronous)
        memory_adapter&.set(feature_name, key, value)

        # Record local write so the subscriber skips self-invalidation
        record_local_write(feature_name)

        # Update Redis if available
        if redis_adapter
          update_redis = proc do
            circuit_breaker.call do
              redis_adapter.set(feature_name, key, value)
            end
          rescue AdapterError => e
            warn "Failed to update Redis: #{e.message}" if defined?(Rails) && Rails.env.development?
          end

          if @async && defined?(Thread)
            Thread.new do
              update_redis.call
              # Publish AFTER Redis write so other processes read fresh data
              publish_cache_invalidation(feature_name)
            end
          else
            update_redis.call
            publish_cache_invalidation(feature_name)
          end
        end

        # Always update Active Record if available (as fallback/persistence layer)
        return unless active_record_adapter

        begin
          active_record_adapter.set(feature_name, key, value)
        rescue AdapterError => e
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

      # Load all keys for a single feature in one call instead of N separate get() calls
      def get_all_data(feature_name)
        # Try memory first
        if memory_adapter
          data = memory_adapter.get_all_data(feature_name)
          return data unless data.nil? || data.empty?
        end

        # Fall back to Redis
        if redis_adapter
          begin
            data = redis_adapter.get_all_data(feature_name)
            if data && !data.empty?
              memory_adapter.set_all_data(feature_name, data) if memory_adapter
              return data
            end
          rescue StandardError, AdapterError
            # Redis failed, continue
          end
        end

        # Fall back to Active Record
        if active_record_adapter
          begin
            data = active_record_adapter.get_all_data(feature_name)
            if data && !data.empty?
              memory_adapter.set_all_data(feature_name, data) if memory_adapter
              return data
            end
          rescue StandardError, AdapterError
            # AR failed
          end
        end

        {}
      end

      # Bulk load ALL features into memory cache in minimal queries.
      # Call this after configuration to warm the cache.
      def preload!
        all_data = {}

        # Load from ActiveRecord first (source of truth for persistence)
        if active_record_adapter
          begin
            all_data = active_record_adapter.load_all_features_data
          rescue StandardError, AdapterError
            # AR failed, try Redis
          end
        end

        # Merge/override with Redis data (more up-to-date than AR in most setups)
        if redis_adapter
          begin
            redis_data = redis_adapter.load_all_features_data
            redis_data.each do |feature_name, data|
              all_data[feature_name] ||= {}
              all_data[feature_name].merge!(data)
            end
          rescue StandardError, AdapterError
            # Redis failed, use what we have from AR
          end
        end

        # Populate memory cache in bulk
        if memory_adapter && !all_data.empty?
          all_data.each do |feature_name, data|
            memory_adapter.set_all_data(feature_name, data)
          end
        end

        all_data
      end

      # Bulk set multiple keys for a feature in one call (1 query instead of N)
      def set_all_data(feature_name, data_hash)
        memory_adapter&.set_all_data(feature_name, data_hash)

        # Record local write so the subscriber skips self-invalidation
        record_local_write(feature_name)

        if redis_adapter
          update_redis = proc do
            circuit_breaker.call do
              redis_adapter.set_all_data(feature_name, data_hash)
            end
          rescue AdapterError => e
            warn "Failed to bulk update Redis: #{e.message}" if defined?(Rails) && Rails.env.development?
          end

          if @async && defined?(Thread)
            Thread.new do
              update_redis.call
              # Publish AFTER Redis write so other processes read fresh data
              publish_cache_invalidation(feature_name)
            end
          else
            update_redis.call
            publish_cache_invalidation(feature_name)
          end
        end

        if active_record_adapter
          begin
            active_record_adapter.set_all_data(feature_name, data_hash)
          rescue AdapterError => e
            warn "Failed to bulk update Active Record: #{e.message}" if defined?(Rails) && Rails.env.development?
          end
        end
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

        redis_adapter.client
      end

      # Publish cache invalidation message to Redis Pub/Sub (without deleting local memory cache)
      # This is useful when you've just updated the cache and want to notify other processes
      # but keep the local memory cache intact
      def publish_cache_invalidation(feature_name)
        return unless redis_adapter

        begin
          redis_client = redis_adapter.client
          redis_client&.publish(CACHE_INVALIDATION_CHANNEL, feature_name.to_s)
        rescue StandardError => e
          # Silently fail - cache invalidation is best effort
          warn "Failed to publish cache invalidation: #{e.message}" if defined?(Rails) && Rails.env.development?
        end
      end

      private

      attr_reader :memory_adapter, :redis_adapter, :active_record_adapter, :circuit_breaker

      # Signal the subscribe loop to return, then close the connection so any
      # retry/reconnect attempt fails fast instead of sleeping for 5s.
      def close_subscriber_connection(subscriber)
        return unless subscriber

        begin
          subscriber.unsubscribe(CACHE_INVALIDATION_CHANNEL)
        rescue StandardError
          # connection may already be dead; fall through to close/kill
        end

        begin
          subscriber.close
        rescue StandardError
          # ignore: best-effort close
        end
      end

      def terminate_subscriber_thread(thread, timeout)
        return unless thread
        return if thread.join(timeout)

        thread.kill
        thread.join(1) # give it a moment to actually unwind
      end

      # Record that this process just wrote a feature, so the subscriber
      # ignores its own Pub/Sub messages and doesn't revert the correct in-memory state.
      def record_local_write(feature_name)
        @reload_mutex.synchronize do
          @local_writes[feature_name.to_s] = Time.now.to_f
          # Also sweep stale tracking entries on the write path — a write-heavy
          # process that rarely reads would otherwise never trigger cleanup,
          # letting @local_writes and @last_reload_times grow unboundedly.
          cleanup_stale_tracking_entries
        end
      end

      # Check if a feature was recently written by this process
      def local_write?(feature_name_str)
        @reload_mutex.synchronize do
          # Periodic cleanup of stale entries to prevent unbounded growth
          cleanup_stale_tracking_entries

          wrote_at = @local_writes[feature_name_str]
          return false unless wrote_at

          if (Time.now.to_f - wrote_at) < LOCAL_WRITE_TTL
            true
          else
            @local_writes.delete(feature_name_str)
            false
          end
        end
      end

      # Clean up stale entries from tracking hashes (called under mutex)
      def cleanup_stale_tracking_entries
        now = Time.now.to_f
        return if @last_tracking_cleanup && (now - @last_tracking_cleanup) < 60.0

        @last_tracking_cleanup = now
        @local_writes.delete_if { |_, wrote_at| (now - wrote_at) >= LOCAL_WRITE_TTL }
        @last_reload_times.delete_if { |_, reload_at| (now - reload_at) >= 10.0 }
      end

      # Start a background thread to listen for cache invalidation messages
      def start_cache_invalidation_subscriber
        return unless redis_adapter && defined?(Thread)

        # Skip subscriber in test environments to avoid RSpec mock conflicts
        # In tests, cache invalidation across processes isn't needed anyway
        return if defined?(Rails) && Rails.env.test?

        @subscriber_thread = Thread.new do
          redis_client = redis_adapter.client
          return unless redis_client

          begin
            # Wrap dup in error handling to catch RSpec mock errors
            @subscriber = redis_client.dup
          rescue StandardError => e
            # In test environments, RSpec mocks might interfere with Redis initialization
            # Silently skip subscriber if dup fails (likely due to test mocks)
            # Check for RSpec mock errors by looking at the error message or class
            is_rspec_error = e.class.name&.include?('RSpec') ||
                             e.message&.include?('stub') ||
                             e.message&.include?('mock') ||
                             (defined?(Rails) && Rails.env.test?)
            return if is_rspec_error

            # Re-raise in non-test environments for unexpected errors
            raise
          end

          @subscriber.subscribe(CACHE_INVALIDATION_CHANNEL) do |on|
            on.message do |_channel, feature_name|
              feature_name_str = feature_name.to_s

              # Reject malformed payloads before doing anything with them.
              # A shared Redis DB is not a trust boundary — reject anything
              # that isn't a plausible feature identifier.
              unless FEATURE_NAME_PATTERN.match?(feature_name_str)
                if defined?(Rails) && Rails.env.development?
                  warn "Magick: ignoring malformed pubsub payload (#{feature_name_str.bytesize}B)"
                end
                next
              end

              # Skip self-invalidation: if this process just wrote this feature,
              # memory already has the correct value. Reloading from Redis would
              # revert it to stale data (especially with async writes).
              if local_write?(feature_name_str)
                if defined?(Rails) && Rails.env.development?
                  Rails.logger.debug "Magick: Skipping self-invalidation for '#{feature_name_str}'"
                end
                next
              end

              # Debounce: only reload if we haven't reloaded this feature in the last 100ms
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

              # Reload the feature instance from the adapter (Redis should have fresh data
              # since remote processes publish AFTER their Redis write completes)
              if defined?(Magick) && Magick.features.key?(feature_name_str)
                feature = Magick.features[feature_name_str]
                if feature.respond_to?(:reload)
                  feature.reload
                  if defined?(Rails) && Rails.env.development?
                    Rails.logger.debug "Magick: Reloaded feature '#{feature_name_str}' after cache invalidation"
                  end
                end
              end
            rescue StandardError => e
              # Log error but don't crash the subscriber thread
              # Skip logging RSpec mock errors in test environments
              is_rspec_error = e.class.name&.include?('RSpec') ||
                               e.message&.include?('stub') ||
                               e.message&.include?('mock') ||
                               (defined?(Rails) && Rails.env.test?)
              if is_rspec_error
                # Silently ignore errors in test environments
                next
              end

              if defined?(Rails) && Rails.env.development?
                warn "Magick: Error processing cache invalidation for '#{feature_name}': #{e.message}"
              end
            end
          end
        rescue StandardError => e
          # If subscription fails, log and retry after a delay
          # Skip retrying in test environments or if it's an RSpec mock error
          is_rspec_error = e.class.name&.include?('RSpec') ||
                           e.message&.include?('stub') ||
                           e.message&.include?('mock') ||
                           (defined?(Rails) && Rails.env.test?)
          return if is_rspec_error

          # Stop cleanly during app shutdown instead of sleeping + retrying,
          # which would keep the process alive and delay termination.
          return if @stopping

          warn "Cache invalidation subscriber error: #{e.message}" if defined?(Rails) && Rails.env.development?
          sleep 5
          retry unless @stopping
        end
        @subscriber_thread.abort_on_exception = false
      end
    end
  end
end
