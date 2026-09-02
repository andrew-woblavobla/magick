# frozen_string_literal: true

require 'json'
require 'securerandom'

module Magick
  module Adapters
    class Registry
      CACHE_INVALIDATION_CHANNEL = 'magick:cache:invalidate'

      # An invalidation message is a small JSON object; anything larger than this
      # did not come from us and is not worth parsing.
      MAX_INVALIDATION_PAYLOAD_BYTES = 512

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
        @stopping = false
        @shutdown_mutex = Mutex.new
        @owner_pid = Process.pid
        @identity_mutex = Mutex.new
        @publisher_id_pid = Process.pid
        @publisher_id = generate_publisher_id
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
        value = redis_read { |redis| redis.get(feature_name, key) }
        if !value.nil? && memory_adapter
          memory_adapter.set(feature_name, key, value)
          return value
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

        # Update Redis if available
        if redis_adapter
          update_redis = proc do
            write_to_redis(:set, feature_name) { redis_adapter.set(feature_name, key, value) }
          end

          if @async && defined?(Thread)
            spawn_async_write(feature_name, update_redis)
          else
            publish_cache_invalidation(feature_name) if update_redis.call
          end
        end

        # Always update Active Record if available (as fallback/persistence layer)
        return unless active_record_adapter

        write_to_active_record(:set, feature_name) { active_record_adapter.set(feature_name, key, value) }
      end

      def delete(feature_name)
        memory_adapter&.delete(feature_name)

        if redis_adapter
          # Behind the breaker like every other Redis write, and the peers are
          # only told to reload once Redis has actually forgotten the feature.
          deleted = write_to_redis(:delete, feature_name) { redis_adapter.delete(feature_name) }
          publish_cache_invalidation(feature_name) if deleted
        end

        return unless active_record_adapter

        write_to_active_record(:delete, feature_name) { active_record_adapter.delete(feature_name) }
      end

      # Fail-safe by contract: an unreachable backend means "not found", never
      # an exception. Callers reach this from outside the fail-safe evaluation
      # path, where a raise would surface as a 500 rather than a disabled flag.
      def exists?(feature_name)
        return true if safely(false) { memory_adapter&.exists?(feature_name) }
        return true if redis_read { |redis| redis.exists?(feature_name) } == true
        return true if safely(false) { active_record_adapter&.exists?(feature_name) } == true

        false
      end

      def all_features
        features = []
        features += safely([]) { memory_adapter&.all_features } || []
        features += redis_read { |redis| redis.all_features } || []
        features += safely([]) { active_record_adapter&.all_features } || []
        # Version history and audit history are stored under reserved
        # pseudo-feature namespaces; they are bookkeeping, not features.
        features.uniq.reject { |f| reserved_store_name?(f) }
      end

      # Load all keys for a single feature in one call instead of N separate get() calls
      def get_all_data(feature_name)
        # Try memory first
        if memory_adapter
          data = memory_adapter.get_all_data(feature_name)
          return data unless data.nil? || data.empty?
        end

        # Fall back to Redis
        data = redis_read { |redis| redis.get_all_data(feature_name) }
        if data && !data.empty?
          memory_adapter.set_all_data(feature_name, data) if memory_adapter
          return data
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

      # Read a feature's complete data straight from the shared, authoritative
      # backend — ActiveRecord first (it is written synchronously on every
      # set/set_all_data), then Redis — bypassing this process's local memory
      # cache, and refresh memory with the result.
      #
      # The Admin UI uses this so a toggle is reflected immediately on whichever
      # process/container serves the (load-balanced) request after the write,
      # instead of rendering this process's possibly-stale memory cache while it
      # waits for Pub/Sub invalidation to arrive.
      def authoritative_get_all_data(feature_name)
        data = read_from_source(feature_name)
        if data && !data.empty?
          memory_adapter&.set_all_data(feature_name, data)
          return data
        end

        # Source unavailable (Redis/AR down, or feature absent there) — fall back
        # to whatever this process already has rather than wiping a usable cache.
        memory_adapter ? memory_adapter.get_all_data(feature_name) : {}
      end

      # Bulk variant of #authoritative_get_all_data: refresh the local memory
      # cache for EVERY feature from the shared backend in 1-2 queries. Returns
      # the loaded data. Used by the Admin UI index so the full list reflects
      # authoritative state regardless of which container serves it.
      def refresh_all_from_source
        data = load_all_from_source
        if memory_adapter && !data.empty?
          data.each { |feature_name, feature_data| memory_adapter.set_all_data(feature_name, feature_data) }
        end
        data
      end

      # Bulk load ALL features into memory cache in minimal queries.
      # Call this after configuration to warm the cache.
      #
      # Version snapshots and audit history are skipped, exactly as
      # #all_features skips them: both are unbounded bookkeeping, and pulling
      # the version archive into every worker's memory cache at boot cost tens
      # of megabytes per worker on installs with a few thousand versions.
      def preload!
        all_data = {}

        # Load from ActiveRecord first (source of truth for persistence)
        if active_record_adapter
          begin
            all_data = load_features_only(active_record_adapter)
          rescue StandardError, AdapterError
            # AR failed, try Redis
          end
        end

        # Merge/override with Redis data (more up-to-date than AR in most setups)
        redis_data = redis_read { |redis| load_features_only(redis) }
        redis_data&.each do |feature_name, data|
          all_data[feature_name] ||= {}
          all_data[feature_name].merge!(data)
        end

        # Reserved bookkeeping namespaces (version snapshots, audit history)
        # are not features: keep their blobs out of the feature cache.
        all_data = all_data.reject { |feature_name, _| reserved_store_name?(feature_name) }

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

        if redis_adapter
          update_redis = proc do
            write_to_redis(:set_all_data, feature_name) { redis_adapter.set_all_data(feature_name, data_hash) }
          end

          if @async && defined?(Thread)
            spawn_async_write(feature_name, update_redis)
          else
            publish_cache_invalidation(feature_name) if update_redis.call
          end
        end

        return unless active_record_adapter

        write_to_active_record(:set_all_data, feature_name) do
          active_record_adapter.set_all_data(feature_name, data_hash)
        end
      end

      # Remove one key from a feature across every configured layer.
      #
      # No local-write bookkeeping is needed: self-invalidation is keyed on the
      # publisher of each message, so this process's own echo is recognised by
      # identity — and #delete_key does not publish at all.
      def delete_key(feature_name, key)
        deleted = false
        [memory_adapter, redis_adapter, active_record_adapter].compact.each do |adapter|
          deleted = true if safely_delete_key(adapter, feature_name, key)
        end
        deleted
      end

      # Allocate a number from a shared counter. Unlike #set this deliberately
      # does NOT fan out to every layer: a counter must have exactly one
      # authority, or two processes reading different layers would be handed the
      # same number. ActiveRecord is preferred (durable, row-locked), then
      # Redis (atomic HINCRBY), then this process's memory as a last resort.
      def next_sequence(feature_name, key, floor: 0)
        [active_record_adapter, redis_adapter, memory_adapter].compact.each do |adapter|
          value = begin
            adapter.next_sequence(feature_name, key, floor: floor)
          rescue StandardError, AdapterError, NotImplementedError
            nil
          end
          return value if value
        end
        nil
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
          # Through the breaker for two reasons: PUBLISH is a Redis round-trip
          # like any other and must not block a request thread on a dead
          # server, and an open circuit means this process cannot have written
          # the new value — inviting peers to reload would hand them the
          # pre-toggle state.
          circuit_breaker.call do
            redis_client = redis_adapter.client
            redis_client&.publish(CACHE_INVALIDATION_CHANNEL, invalidation_message(feature_name))
          end
        rescue CircuitOpenError
          AdapterFailure.report(backend: :redis, operation: :publish_cache_invalidation,
                                feature_name: feature_name, reason: 'circuit breaker open')
        rescue StandardError => e
          # Best effort for this process, but a dropped invalidation leaves every
          # OTHER process holding a stale value, so it is reported like any other
          # failed write rather than swallowed.
          AdapterFailure.report(backend: :redis, operation: :publish_cache_invalidation,
                                feature_name: feature_name, error: e)
        end
      end

      # This registry's identity on the invalidation channel. Every message it
      # publishes carries it, and it is the ONLY thing the subscriber suppresses
      # on: a message is ignored when we published it, and acted on otherwise.
      #
      # Per-registry rather than per-process, so two registries sharing a process
      # still see each other's writes; random, because PIDs collide across
      # containers.
      def publisher_id
        @identity_mutex.synchronize do
          # A forked child inherits the parent's identity along with the rest of
          # its memory. Re-mint it so parent and child do not each mistake the
          # other's invalidations for their own echo and ignore them.
          if @publisher_id_pid != Process.pid
            @publisher_id_pid = Process.pid
            @publisher_id = generate_publisher_id
          end
          @publisher_id
        end
      end

      # Public so Versioning can apply tiered retention: hot window written to
      # memory/Redis, unlimited archive written to ActiveRecord only.
      attr_reader :memory_adapter, :redis_adapter, :active_record_adapter

      private

      attr_reader :circuit_breaker

      def safely_delete_key(adapter, feature_name, key)
        adapter.delete_key(feature_name, key)
      rescue StandardError, AdapterError, NotImplementedError
        false
      end

      # Version snapshots and audit history live under reserved pseudo-feature
      # namespaces. The constants are resolved lazily because those classes are
      # loaded after this one.
      def reserved_store_prefixes
        [Versioning::STORE_PREFIX, AuditLog::STORE_PREFIX]
      end

      def reserved_store_name?(name)
        name = name.to_s
        reserved_store_prefixes.any? { |prefix| name.start_with?(prefix) }
      end

      # Every Redis read goes through here. Reads used to call the adapter
      # directly, which left the breaker protecting the write path only: a
      # Redis that black-holes packets rather than refusing connections would
      # stall a request thread for the driver's timeout on every single lookup
      # while the breaker sat open doing nothing.
      #
      # Returns nil when Redis is absent, the circuit is open, or the call
      # failed — the caller then falls through to the next adapter. Read
      # failures are not reported: unlike a write, falling through to the next
      # adapter leaves nothing diverged.
      def redis_read
        return nil unless redis_adapter

        circuit_breaker.call { yield redis_adapter }
      rescue StandardError
        nil
      end

      # Run a backend call that must never raise at the registry boundary,
      # substituting `fallback` when it does.
      def safely(fallback)
        yield
      rescue StandardError
        fallback
      end

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

      # Run a Redis write through the circuit breaker. Returns true when the
      # write landed, false when it failed or was dropped.
      #
      # Memory was already written and is never rolled back, so every false here
      # means this process is serving a value the rest of the fleet does not
      # have. That is reported before returning, never swallowed. The failure
      # itself is contained: a broken backend must not raise into the caller.
      def write_to_redis(operation, feature_name)
        circuit_breaker.call { yield }
        true
      rescue CircuitOpenError
        # An open breaker drops the write without ever calling the adapter, so
        # the drop has to be reported on its own — otherwise a backend that
        # stays down goes quiet after the breaker trips, which is exactly the
        # window in which divergence accumulates. Reported as a reason rather
        # than an error: nothing went wrong here, the write simply never
        # happened.
        AdapterFailure.report(backend: :redis, operation: operation, feature_name: feature_name,
                              reason: 'circuit breaker open')
        false
      rescue StandardError => e
        AdapterFailure.report(backend: :redis, operation: operation, feature_name: feature_name, error: e)
        false
      end

      # Same contract as #write_to_redis, for the ActiveRecord persistence layer.
      def write_to_active_record(operation, feature_name)
        yield
        true
      rescue StandardError => e
        AdapterFailure.report(backend: :active_record, operation: operation, feature_name: feature_name, error: e)
        false
      end

      # Fire-and-forget async Redis write. Wrapped so that a failure in the
      # update or publish step is reported rather than silently killing the
      # thread — Thread#abort_on_exception is false, which otherwise swallows
      # the error completely.
      def spawn_async_write(feature_name, update_redis)
        thread = Thread.new do
          publish_cache_invalidation(feature_name) if update_redis.call
        rescue StandardError => e
          AdapterFailure.report(backend: :redis, operation: :async_write, feature_name: feature_name, error: e)
        end
        thread.name = "magick-async-write-#{feature_name}" if thread.respond_to?(:name=)
        thread.abort_on_exception = false
        thread
      end

      # Handle one cache-invalidation message: refresh this process's view of
      # the feature from the shared backend. Returns true when the message was
      # acted on, false when it was rejected/skipped (used by specs).
      #
      # Suppression is keyed on WHO PUBLISHED the message, never on when we last
      # wrote. A peer's message is always acted on, however close it lands to our
      # own write: two containers toggling the same flag seconds apart must each
      # end up on the shared store's value, and a "did I write this recently"
      # window silently dropped exactly those messages, leaving both containers
      # serving their own value indefinitely.
      #
      # Every peer message triggers a full-state reload. A single enable/disable
      # emits two publishes (targeting then value); each reload reads the
      # feature's COMPLETE current state, so processing every message is
      # idempotent, and feature-flag writes are admin-rate — redundant reloads
      # are cheap and rare.
      def process_cache_invalidation(payload)
        raw = payload.to_s
        feature_name_str, publisher = parse_invalidation_message(raw)

        # Reject malformed payloads before doing anything with them. A shared
        # Redis DB is not a trust boundary — reject anything that isn't a
        # plausible feature identifier.
        unless FEATURE_NAME_PATTERN.match?(feature_name_str)
          warn "Magick: ignoring malformed pubsub payload (#{raw.bytesize}B)" if rails_development?
          return false
        end

        # Our own echo: memory already holds what we just wrote, and reloading
        # could revert it to pre-write data (async writes publish after the Redis
        # write). Only OUR messages are dropped here.
        if publisher == publisher_id
          Rails.logger.debug "Magick: Ignoring own invalidation for '#{feature_name_str}'" if rails_development?
          return false
        end

        # Invalidate the local memory cache, then reload the registered feature
        # instance from the shared backend (the publisher writes Redis/AR BEFORE
        # publishing, so fresh data is available by now).
        memory_adapter&.delete(feature_name_str)
        if defined?(Magick) && Magick.respond_to?(:features) && Magick.features.key?(feature_name_str)
          feature = Magick.features[feature_name_str]
          if feature.respond_to?(:reload)
            feature.reload
            Rails.logger.debug "Magick: Reloaded '#{feature_name_str}' after cache invalidation" if rails_development?
          end
        end
        true
      end

      def rails_development?
        defined?(Rails) && Rails.respond_to?(:env) && Rails.env.development?
      end

      # Read a feature's full data from the shared, authoritative backend,
      # skipping the local memory cache. ActiveRecord is preferred because it is
      # written synchronously on every set (Redis may lag under async_updates).
      def read_from_source(feature_name)
        if active_record_adapter
          begin
            data = active_record_adapter.get_all_data(feature_name)
            return data if data && !data.empty?
          rescue StandardError, AdapterError
            # fall through to Redis
          end
        end

        redis_read { |redis| redis.get_all_data(feature_name) }
      end

      # Bulk read ALL features from the shared, authoritative backend, skipping
      # the local memory cache. AR preferred (synchronous), Redis fallback.
      # Reserved namespaces are skipped for the same reason as in #preload!,
      # and it matters more here: this runs on every Admin UI index render.
      def load_all_from_source
        if active_record_adapter
          begin
            data = load_features_only(active_record_adapter)
            return data unless data.empty?
          rescue StandardError, AdapterError
            # fall through to Redis
          end
        end

        redis_read { |redis| load_features_only(redis) } || {}
      end

      # Everything in the store except the reserved bookkeeping namespaces.
      # The adapters filter in the store, so those rows are never read at all —
      # discarding an unbounded archive after loading it still pays for the
      # read. The reject that follows is a backstop for a custom adapter that
      # inherits the base implementation instead of overriding it.
      def load_features_only(adapter)
        data = if adapter.respond_to?(:load_features_data_without_prefixes)
                 adapter.load_features_data_without_prefixes(reserved_store_prefixes)
               else
                 adapter.load_all_features_data
               end
        without_reserved_stores(data)
      end

      def without_reserved_stores(data)
        return {} unless data.is_a?(Hash)

        data.reject { |feature_name, _| reserved_store_name?(feature_name) }
      end

      # Wire format of an invalidation message: which feature changed, and which
      # registry changed it.
      def invalidation_message(feature_name)
        JSON.generate('feature' => feature_name.to_s, 'publisher' => publisher_id)
      end

      # Returns [feature_name, publisher_id]. A bare feature name — what older
      # processes publish — parses as a message with no publisher, which is
      # therefore never mistaken for our own and is always acted on.
      def parse_invalidation_message(raw)
        return ['', nil] if raw.bytesize > MAX_INVALIDATION_PAYLOAD_BYTES
        return [raw, nil] unless raw.start_with?('{')

        message = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end
        return ['', nil] unless message.is_a?(Hash)

        [message['feature'].to_s, message['publisher']]
      end

      def generate_publisher_id
        "#{Process.pid}-#{SecureRandom.hex(8)}"
      end

      # Start a background thread to listen for cache invalidation messages
      def start_cache_invalidation_subscriber
        return unless redis_adapter && defined?(Thread)

        # Skip subscriber in test environments to avoid RSpec mock conflicts
        # In tests, cache invalidation across processes isn't needed anyway
        return if defined?(Rails) && Rails.env.test?

        @subscriber_thread = Thread.new do
          redis_client = redis_adapter.client
          # `next`, not `return`: `return` from a block raises LocalJumpError,
          # which the block-level rescue below would treat as a subscription
          # failure and spin on. `next` ends the thread, which is what these
          # guards mean.
          next unless redis_client

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
            next if is_rspec_error

            # Re-raise in non-test environments for unexpected errors
            raise
          end

          @subscriber.subscribe(CACHE_INVALIDATION_CHANNEL) do |on|
            on.message do |_channel, payload|
              process_cache_invalidation(payload)
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
                warn "Magick: Error processing cache invalidation for '#{Magick::LogSafe.sanitize(payload)}': #{Magick::LogSafe.sanitize(e.message)}"
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
          next if is_rspec_error

          # Stop cleanly during app shutdown instead of sleeping + retrying,
          # which would keep the process alive and delay termination.
          next if @stopping

          warn "Cache invalidation subscriber error: #{e.message}" if defined?(Rails) && Rails.env.development?
          sleep 5
          retry unless @stopping
        end
        @subscriber_thread.abort_on_exception = false
      end
    end
  end
end
