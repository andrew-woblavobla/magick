# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'

module Magick
  # Records one entry per logical feature mutation (see Feature#record_change).
  #
  # Storage is two-tiered, mirroring Versioning:
  #
  #   * a process-local ring of the last `max_entries` entries across all
  #     features, for fast reads of what this process just did;
  #   * a durable, shared store holding the last `retention` entries per
  #     feature in every adapter that outlives the process (Redis and/or
  #     ActiveRecord), so history survives a restart and every container can
  #     answer "who changed this flag" about changes made anywhere else.
  #
  # A memory-only deployment has nothing that outlives the process, so it
  # keeps only the ring — that is inherent, not a fallback.
  class AuditLog
    class Entry
      attr_reader :id, :feature_name, :action, :user_id, :timestamp, :changes, :metadata

      def initialize(feature_name, action, user_id: nil, changes: {}, metadata: {}, timestamp: nil, id: nil)
        @feature_name = feature_name.to_s
        @action = action.to_s
        @user_id = user_id
        @timestamp = timestamp || Time.now
        @changes = changes || {}
        @metadata = metadata || {}
        @id = (id.nil? || id.to_s.empty? ? self.class.generate_id(@timestamp) : id.to_s)
      end

      def to_h
        {
          id: id,
          feature_name: feature_name,
          action: action,
          user_id: user_id,
          timestamp: timestamp.iso8601,
          changes: changes,
          metadata: metadata
        }
      end

      # Sortable, collision-free id: milliseconds since the epoch, then a
      # per-process sequence, then randomness. All fields are fixed width, so
      # sorting ids as strings orders entries chronologically — including
      # entries written in the same second, which the iso8601 timestamp
      # (second resolution) cannot distinguish after a storage round trip.
      def self.generate_id(timestamp)
        format(
          '%<millis>013d-%<sequence>09d-%<random>s',
          millis: (timestamp.to_f * 1000).floor,
          sequence: next_sequence,
          random: SecureRandom.hex(4)
        )
      end

      SEQUENCE_MUTEX = Mutex.new
      SEQUENCE_LIMIT = 1_000_000_000
      private_constant :SEQUENCE_MUTEX, :SEQUENCE_LIMIT

      def self.next_sequence
        SEQUENCE_MUTEX.synchronize do
          @sequence = ((@sequence || 0) + 1) % SEQUENCE_LIMIT
        end
      end

      # Rebuild an entry from a stored hash. Adapters hand back string keys
      # (Redis/JSON) or symbol keys (ActiveRecord), so accept both.
      def self.from_h(raw)
        data = raw.is_a?(Hash) ? raw : nil
        return nil unless data

        name = fetch(data, :feature_name)
        return nil if name.nil?

        new(
          name,
          fetch(data, :action),
          user_id: fetch(data, :user_id),
          changes: deep_symbolize(fetch(data, :changes)) || {},
          metadata: deep_symbolize(fetch(data, :metadata)) || {},
          timestamp: parse_time(fetch(data, :timestamp)),
          id: fetch(data, :id)
        )
      end

      def self.fetch(data, key)
        value = data[key]
        value = data[key.to_s] if value.nil?
        value
      end
      private_class_method :fetch

      def self.parse_time(value)
        return value if value.is_a?(Time)
        return nil unless value.is_a?(String)

        begin
          Time.parse(value)
        rescue ArgumentError
          nil
        end
      end
      private_class_method :parse_time

      def self.deep_symbolize(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), out| out[k.to_sym] = deep_symbolize(v) }
        when Array
          obj.map { |v| deep_symbolize(v) }
        else
          obj
        end
      end
      private_class_method :deep_symbolize
    end

    # Durable, shared audit storage layered on the adapter registry. Entries
    # live under a reserved pseudo-feature namespace, one capped list per
    # feature, so feature reads never drag audit history along and deleting a
    # feature does not destroy the record of who changed it.
    class Store
      ENTRIES_KEY = 'entries'

      attr_reader :registry, :retention

      def initialize(registry, retention:)
        @registry = registry
        @retention = retention
      end

      def durable?
        !durable_adapters.empty?
      end

      # Append one entry to the shared list for its feature.
      #
      # `recent` is this process's tail of the ring: merging it back in means
      # an entry that lost a read-modify-write race against another container
      # is restored by this process's next write, instead of being dropped.
      def write(entry, recent = [])
        adapters = durable_adapters
        return false if adapters.empty?

        name = entry.feature_name
        known = recent.select { |e| e.feature_name == name }
        payload = AuditLog.merge(read(name) + known + [entry], limit: retention).map(&:to_h)
        adapters.each { |adapter| swallow { adapter.set(store_name(name), ENTRIES_KEY, payload) } }
        true
      end

      # Read straight from the shared adapters — never through the registry,
      # whose memory-first lookup would answer with this process's own cache
      # and hide entries written by other processes.
      def read(feature_name)
        durable_adapters.flat_map do |adapter|
          entries_from(swallow { adapter.get(store_name(feature_name), ENTRIES_KEY) })
        end
      end

      # Every feature's audit history, in one call per adapter.
      def read_all
        durable_adapters.flat_map { |adapter| audit_stores_in(swallow { adapter.load_all_features_data }) }
      end

      private

      def audit_stores_in(data)
        return [] unless data.is_a?(Hash)

        data.flat_map do |name, feature_data|
          next [] unless name.to_s.start_with?(STORE_PREFIX) && feature_data.is_a?(Hash)

          entries_from(feature_data[ENTRIES_KEY] || feature_data[ENTRIES_KEY.to_sym])
        end
      end

      # Adapters whose contents outlive this process. The memory adapter is
      # excluded on purpose: it is neither durable nor shared, and the ring
      # already covers everything this process wrote.
      def durable_adapters
        candidates =
          if registry.respond_to?(:redis_adapter) && registry.respond_to?(:active_record_adapter)
            [registry.redis_adapter, registry.active_record_adapter]
          else
            [registry]
          end

        candidates.compact.reject { |adapter| adapter.is_a?(Magick::Adapters::Memory) }
      end

      def entries_from(raw)
        raw = parse_json(raw) if raw.is_a?(String)
        return [] unless raw.is_a?(Array)

        raw.filter_map { |item| Entry.from_h(item) }
      end

      def parse_json(str)
        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end

      def store_name(feature_name)
        "#{STORE_PREFIX}#{feature_name}"
      end

      # Audit persistence is best-effort: a flaky backend must never turn a
      # feature toggle into an exception.
      def swallow
        yield
      rescue StandardError => e
        warn "Magick: audit store unavailable: #{Magick::LogSafe.sanitize(e.message)}" if rails_development?
        nil
      end

      def rails_development?
        defined?(Rails) && Rails.respond_to?(:env) && Rails.env.development?
      end
    end

    # Entries per process, across all features. Bounds memory in a
    # long-running process; not a durability setting.
    DEFAULT_MAX_ENTRIES = 10_000

    # Entries kept per feature in the durable, shared store.
    DEFAULT_RETENTION = 200

    # Reserved pseudo-feature namespace the durable store writes under.
    STORE_PREFIX = '__magick_audit:'

    def initialize(adapter = nil, max_entries: DEFAULT_MAX_ENTRIES, retention: DEFAULT_RETENTION,
                   adapter_registry: nil, persist: true)
      @adapter = adapter
      @logs = []
      @max_entries = positive_or(max_entries, DEFAULT_MAX_ENTRIES)
      @retention = positive_or(retention, DEFAULT_RETENTION)
      @persist = persist != false
      @adapter_registry = adapter_registry
      @mutex = Mutex.new
    end

    attr_reader :max_entries, :retention

    def log(feature_name, action, user_id: nil, changes: {}, metadata: {})
      entry = Entry.new(feature_name, action, user_id: user_id, changes: changes, metadata: metadata)

      recent = @mutex.synchronize do
        @logs << entry
        # Cap in-memory ring; older entries fall out once we cross the limit.
        # This keeps long-running processes from growing @logs unboundedly.
        @logs.shift while @logs.size > @max_entries
        @logs.last(@retention)
      end

      # Both writes run OUTSIDE @mutex: that lock guards the in-memory ring
      # only, so a database- or Redis-backed sink never serializes every
      # feature mutation in the process behind it.
      persist(entry, recent)
      append_to_adapter(entry)

      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.audit_logged(feature_name, action: action, user_id: user_id, changes: changes, **metadata)
      end

      entry
    end

    # Merges the durable, shared history with this process's ring, so a
    # process sees both what it did itself and what other processes did.
    def entries(feature_name: nil, limit: 100)
      local = @mutex.synchronize { @logs.dup }
      local = local.select { |e| e.feature_name == feature_name.to_s } if feature_name
      durable = feature_name ? store&.read(feature_name) : store&.read_all

      self.class.merge(Array(durable) + local, limit: limit)
    end

    # Entries held by THIS process's ring. Durable history is usually larger;
    # read it with #entries.
    def size
      @mutex.synchronize { @logs.size }
    end

    # True when entries are being written somewhere that survives a restart.
    def durable?
      store&.durable? || false
    end

    # De-duplicate by id (later wins, so a locally created entry beats its
    # round-tripped copy) and order chronologically.
    def self.merge(entries, limit: nil)
      by_id = {}
      entries.each { |entry| by_id[entry.id] = entry if entry }
      merged = by_id.values.sort_by(&:id)
      limit ? merged.last(limit) : merged
    end

    private

    # Best-effort by design: recording who changed a flag must never be the
    # reason the flag failed to change.
    def persist(entry, recent)
      store&.write(entry, recent)
    rescue StandardError => e
      if defined?(Rails) && Rails.respond_to?(:env) && Rails.env.development?
        warn "Magick: failed to persist audit entry: #{Magick::LogSafe.sanitize(e.message)}"
      end
    end

    def append_to_adapter(entry)
      return unless @adapter.respond_to?(:append)

      @adapter.append(entry)
    rescue StandardError => e
      warn "Magick: audit adapter #{@adapter.class} failed to append: #{Magick::LogSafe.sanitize(e.message)}"
    end

    # Resolved lazily: the audit log is usually built before the adapters are
    # configured, and `Magick.adapter_registry` can be replaced afterwards.
    def store
      return nil unless @persist

      registry = @adapter_registry || Magick.adapter_registry || Magick.default_adapter_registry
      return nil unless registry

      @store = Store.new(registry, retention: @retention) unless @store&.registry.equal?(registry)
      @store
    end

    def positive_or(value, default)
      value.to_i.positive? ? value.to_i : default
    end
  end
end
