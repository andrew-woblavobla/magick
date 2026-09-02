# frozen_string_literal: true

require 'json'
require 'time'

module Magick
  class Versioning
    DEFAULT_MAX_VERSIONS = 50

    # Version history lives under a reserved pseudo-feature namespace so that
    # feature reads (get_all_data) never drag snapshot blobs along, and so
    # deleting a feature does not destroy its ActiveRecord archive row.
    STORE_PREFIX = '__magick_versions:'

    # The hot window keeps one store key per snapshot. Appending writes only its
    # own key, so two containers saving at the same time interleave into one
    # history instead of each rewriting the whole list over the other's entries.
    VERSION_KEY_PREFIX = 'version_'
    VERSION_KEY_PATTERN = /\A#{VERSION_KEY_PREFIX}(\d+)\z/.freeze

    # The archive keeps one store ROW per version, not one key per version
    # inside the feature's single row. An ActiveRecord write is a
    # read-modify-write of the whole row blob under a row lock, so appending
    # version N to a shared row rewrote all N-1 predecessors with it; its own
    # row makes an append cost one snapshot no matter how long the history is.
    ARCHIVE_ROW_INFIX = '#v'
    ARCHIVE_DATA_KEY = 'snapshot'

    # The shared counter that hands out version numbers, in a row of its own so
    # that allocating a number never rewrites archived snapshots alongside it.
    SEQUENCE_ROW_SUFFIX = '#seq'
    SEQUENCE_KEY = 'sequence'

    # 1.5.0 wrote the whole hot window as a single JSON list under this key.
    # Still read (and migrated forward on the next append) so history written
    # before the upgrade stays visible.
    LEGACY_WINDOW_KEY = 'versions'

    class Version
      attr_reader :version, :feature_data, :timestamp, :created_by, :action

      def initialize(version, feature_data, created_by: nil, action: nil, timestamp: nil)
        @version = version
        @feature_data = feature_data
        @timestamp = timestamp || Time.now
        @created_by = created_by
        @action = action
      end

      def to_h
        {
          version: version,
          feature_data: feature_data,
          timestamp: timestamp.iso8601,
          created_by: created_by,
          action: action
        }
      end
    end

    def initialize(adapter_registry, max_versions: DEFAULT_MAX_VERSIONS)
      @adapter_registry = adapter_registry
      @max_versions = max_versions.to_i.positive? ? max_versions.to_i : DEFAULT_MAX_VERSIONS
    end

    attr_reader :max_versions

    # Explicit manual snapshot. Kept as public API from earlier releases;
    # since 1.5.0 every Feature mutation also snapshots automatically.
    def save_version(feature_name, version: nil, created_by: nil)
      feature = Magick.features[feature_name.to_s] || Magick[feature_name]
      append(feature.name, snapshot_of(feature), version: version, created_by: created_by, action: 'manual')
    end

    # Called by Feature#record_change after every successful mutation.
    # snapshot: allows callers (delete) to capture state before the mutation.
    def record_change(feature, action: nil, created_by: nil, snapshot: nil)
      data = snapshot ? deep_symbolize(JSON.parse(JSON.generate(snapshot))) : snapshot_of(feature)
      append(feature.name, data, created_by: created_by, action: action)
    end

    # Hot window (last max_versions, memory/Redis) by default; all: true
    # merges the unlimited ActiveRecord archive when one is configured.
    def get_versions(feature_name, all: false)
      name = feature_name.to_s
      hot = hot_entries(name)
      return sorted(hot).last(@max_versions) unless all

      sorted(hot.merge(archive_entries(name)))
    end

    # Restore the feature to the snapshot stored in the given version, then
    # record the rollback itself as a new version + audit entry (history only
    # ever rolls forward). Restores state wholesale: value (including false/
    # empty), status, group, the entire targeting hash, and dependencies.
    def rollback(feature_name, version)
      entry = find_version(feature_name, version)
      return false unless entry

      feature = Magick.features[feature_name.to_s] || Magick[feature_name]
      Magick.suppress_change_recording do
        feature.restore_snapshot!(entry.feature_data)
      end

      actor = Magick.current_actor
      Magick.audit_log&.log(feature_name, 'rollback', user_id: actor, changes: { rolled_back_to: version })
      record_change(feature, action: 'rollback', created_by: actor)

      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.rollback(feature_name, version: version)
      end

      true
    end

    private

    # Deep copy via JSON so stored snapshots never alias the feature's live
    # targeting hash, and in-process entries match adapter-rehydrated ones.
    def snapshot_of(feature)
      deep_symbolize(JSON.parse(JSON.generate(feature.to_h)))
    end

    # Every append re-reads the current history from the store. Nothing is
    # memoized for the process lifetime: a window cached on first read is
    # exactly what let two containers renumber and overwrite each other's
    # snapshots in 1.5.0.
    def append(name, snapshot, version: nil, created_by: nil, action: nil)
      stored = hot_store_data(name)
      history = stored.values.each_with_object({}) { |data, all| all.merge!(entries_in(data)) }
      migrate_legacy_window(name, stored)

      number = version ? version.to_i : allocate_version_number(name, history)
      entry = Version.new(number, snapshot, created_by: created_by, action: action)
      persist(name, entry)
      prune_hot_window(name, history.keys, number)

      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.version_saved(name, version: entry.version, created_by: created_by)
      end

      entry
    end

    # The shared store allocates the number, so two processes appending at the
    # same time can never be handed the same one. The floor is the highest
    # number this process can see: a store whose counter is missing (upgrade
    # from 1.5.0, Redis flush, restored dump) resumes above the surviving
    # history instead of restarting at 1 and overwriting it.
    def allocate_version_number(name, history)
      adapter = sequence_adapter
      floor = highest_known_version(name, history, adapter)
      return floor + 1 unless adapter

      number = safely { adapter.next_sequence(sequence_row(name), SEQUENCE_KEY, floor: floor) }.to_i
      return number if number > floor

      # No usable allocator (adapter down, or a custom one that does not
      # implement the primitive). Fall back to local numbering — which is what
      # 1.5.0 always did — rather than dropping the snapshot.
      floor + 1
    end

    def highest_known_version(name, history, adapter)
      floor = history.keys.max.to_i
      return floor if adapter.nil?
      return floor unless safely { adapter.get(sequence_row(name), SEQUENCE_KEY) }.nil?

      # First allocation against this store, so the counter is about to be
      # seeded: look at the archive too, which may hold far higher numbers than
      # the hot window that survived.
      [floor, archive_high_water(name)].max
    end

    # The hot window keeps one key per snapshot inside the feature's store
    # entry (memory is a plain hash, Redis an HSET — both write just that key);
    # the archive keeps one row per snapshot, since its adapter rewrites a whole
    # row per write. Either way an append writes one version's worth of data.
    def persist(name, entry)
      payload = entry.to_h
      hot_adapters.each { |adapter| safely { adapter.set(store_name(name), version_key(entry.version), payload) } }
      archive = archive_adapter
      safely { archive.set(archive_row(name, entry.version), ARCHIVE_DATA_KEY, payload) } if archive
    end

    # Retention for the hot window, keyed off the number just allocated rather
    # than off a count of what this process happened to read, so appends racing
    # from several processes agree on what to drop.
    def prune_hot_window(name, known_numbers, allocated)
      threshold = allocated - @max_versions
      return if threshold < 1

      stale = known_numbers.select { |number| number <= threshold }
      return if stale.empty?

      hot_adapters.each do |adapter|
        stale.each { |number| safely { adapter.delete_key(store_name(name), version_key(number)) } }
      end
    end

    # One-time forward migration of the 1.5.0 single-blob window into one key
    # per version, so pre-upgrade snapshots take part in retention and are read
    # the same way everywhere. Idempotent: entries are keyed by their own
    # version number, and the blob is emptied once they have been written.
    def migrate_legacy_window(name, stored)
      stored.each do |adapter, data|
        legacy = legacy_entries(data)
        next if legacy.empty?

        legacy.each_value do |entry|
          safely { adapter.set(store_name(name), version_key(entry.version), entry.to_h) }
        end
        safely { adapter.set(store_name(name), LEGACY_WINDOW_KEY, []) }
      end
    end

    # Current history, keyed by version number. The memory adapter is a
    # per-process cache holding only what this process wrote, so it is never the
    # whole story: Redis is the shared hot window when one is configured, and
    # without Redis the archive is the only place another container's snapshots
    # can be found, so it backs the window too. Also used when the hot store is
    # empty (fresh boot, Redis flush) so history survives a restart.
    def hot_entries(name)
      entries = {}
      hot_store_data(name).each_value { |data| entries.merge!(entries_in(data)) }
      return entries if shared_hot_adapter && !entries.empty?

      entries.merge(archive_entries(name))
    end

    # Redis, when configured: the one hot-window store every process reads.
    def shared_hot_adapter
      registry = @adapter_registry
      registry.respond_to?(:redis_adapter) ? registry.redis_adapter : nil
    end

    # Weakest source first: the process-local memory cache loses to Redis, and
    # both lose to the archive, so a version number resolves to the same
    # snapshot no matter which process is asked.
    def hot_store_data(name)
      hot_adapters.to_h { |adapter| [adapter, adapter_data(adapter, name)] }
    end

    # One row per snapshot, plus whatever an archive written before this layout
    # left inside the feature's single row. Pre-existing history is read in
    # place rather than rewritten: nothing writes to that row any more, so it
    # costs a read and never grows.
    def archive_entries(name)
      adapter = archive_adapter
      return {} unless adapter

      entries = legacy_archive_entries(adapter, name)
      rows = safely { adapter.load_features_data_with_prefix(archive_row_prefix(name)) }
      (rows.is_a?(Hash) ? rows : {}).each do |row, data|
        number = archive_row_number(name, row)
        next unless number

        entry = rehydrate(archived_payload(data))
        entries[entry.version] = entry if entry && entry.version == number
      end
      entries
    end

    # Snapshots an older release wrote as version_<n> keys (or a 1.5.0 list)
    # inside the feature's own archive row.
    def legacy_archive_entries(adapter, name)
      entries_in(adapter_data(adapter, name))
    end

    # Highest archived number, read from row and key names alone: rehydrating an
    # unlimited archive just to find its maximum would be wasteful. Only reached
    # when the store has no counter yet, so this is a once-per-feature cost on
    # upgrade rather than something an append pays.
    def archive_high_water(name)
      adapter = archive_adapter
      return 0 unless adapter

      legacy = adapter_data(adapter, name).keys.filter_map do |key|
        match = VERSION_KEY_PATTERN.match(key.to_s)
        match && match[1].to_i
      end
      (legacy + archive_row_numbers(adapter, name)).max.to_i
    end

    def archive_row_numbers(adapter, name)
      rows = safely { adapter.load_features_data_with_prefix(archive_row_prefix(name)) }
      (rows.is_a?(Hash) ? rows.keys : []).filter_map { |row| archive_row_number(name, row) }
    end

    def adapter_data(adapter, name)
      data = safely { adapter.get_all_data(store_name(name)) }
      data.is_a?(Hash) ? data : {}
    end

    # Version entries held in one already-read blob of store data, keyed by
    # version number. Legacy list entries are read first so a per-version key
    # written by this release wins over a stale copy inside the 1.5.0 blob.
    def entries_in(data)
      entries = legacy_entries(data)
      data.each do |key, value|
        next unless VERSION_KEY_PATTERN.match?(key.to_s)

        entry = rehydrate(value)
        entries[entry.version] = entry if entry
      end
      entries
    end

    def legacy_entries(data)
      raw = data[LEGACY_WINDOW_KEY] || data[LEGACY_WINDOW_KEY.to_sym]
      raw = parse_json(raw) if raw.is_a?(String)
      return {} unless raw.is_a?(Array)

      raw.each_with_object({}) do |item, entries|
        entry = rehydrate(item)
        entries[entry.version] = entry if entry
      end
    end

    def sorted(entries)
      entries.values.sort_by(&:version)
    end

    # Read the snapshot for one number, most authoritative source first — the
    # durable archive, then the shared hot store, then this process's own
    # memory cache — so every process resolves the same number to the same
    # snapshot.
    def find_version(feature_name, version)
      name = feature_name.to_s
      number = version.to_i
      return nil unless number.positive?

      entry = archived_version(name, number)
      return entry if entry

      hot_adapters.reverse_each do |adapter|
        raw = safely { adapter.get(store_name(name), version_key(number)) }
        entry = raw && rehydrate(raw)
        return entry if entry
      end

      # Written before the per-version layout (1.5.0 blob).
      hot_entries(name)[number]
    end

    # Its own row since the archive stopped sharing one; a version_<n> key in
    # the feature's row before that.
    def archived_version(name, number)
      adapter = archive_adapter
      return nil unless adapter

      raw = safely { adapter.get(archive_row(name, number), ARCHIVE_DATA_KEY) }
      raw ||= safely { adapter.get(store_name(name), version_key(number)) }
      raw && rehydrate(raw)
    end

    # Hot window lives in memory + Redis (capped); the ActiveRecord adapter
    # keeps the unlimited archive, one row per entry.
    def hot_adapters
      registry = @adapter_registry
      if registry.respond_to?(:memory_adapter)
        [registry.memory_adapter, registry.redis_adapter].compact
      else
        [registry]
      end
    end

    def archive_adapter
      registry = @adapter_registry
      registry.respond_to?(:active_record_adapter) ? registry.active_record_adapter : nil
    end

    # A counter needs exactly one authority, so this picks a single adapter
    # instead of fanning out like writes do. ActiveRecord first — it is the
    # durable store, and a counter that outlives a Redis flush is the one that
    # cannot hand out a number the archive has already used; then Redis; then,
    # with no shared backend configured at all, this process's own memory.
    def sequence_adapter
      registry = @adapter_registry
      return registry unless registry.respond_to?(:memory_adapter)

      registry.active_record_adapter || registry.redis_adapter || registry.memory_adapter
    end

    def store_name(name)
      "#{STORE_PREFIX}#{name}"
    end

    def version_key(number)
      "#{VERSION_KEY_PREFIX}#{number}"
    end

    def sequence_row(name)
      "#{store_name(name)}#{SEQUENCE_ROW_SUFFIX}"
    end

    def archive_row(name, number)
      "#{archive_row_prefix(name)}#{number}"
    end

    def archive_row_prefix(name)
      "#{store_name(name)}#{ARCHIVE_ROW_INFIX}"
    end

    # The number a row name carries, or nil when it is not an archive row for
    # this feature. A feature literally named "flag#v2" archives under the same
    # prefix as "flag", so the suffix must be a bare number to count: that
    # feature's rows end in "2#v<n>" and are rejected here rather than read as
    # part of "flag"'s history.
    def archive_row_number(name, row)
      row = row.to_s
      prefix = archive_row_prefix(name)
      return nil unless row.start_with?(prefix)

      suffix = row[prefix.length..]
      suffix.match?(/\A\d+\z/) ? suffix.to_i : nil
    end

    # An archive row holds the snapshot under a single key.
    def archived_payload(data)
      return nil unless data.is_a?(Hash)

      data[ARCHIVE_DATA_KEY] || data[ARCHIVE_DATA_KEY.to_sym]
    end

    def rehydrate(raw)
      raw = parse_json(raw) if raw.is_a?(String)
      return nil unless raw.is_a?(Hash)

      data = deep_symbolize(raw)
      number = data[:version].respond_to?(:to_i) ? data[:version].to_i : 0
      return nil unless number.positive?

      Version.new(
        number,
        data[:feature_data] || {},
        created_by: data[:created_by],
        action: data[:action],
        timestamp: parse_timestamp(data[:timestamp])
      )
    end

    def parse_timestamp(value)
      value.is_a?(String) ? safely { Time.parse(value) } : value
    end

    def parse_json(str)
      JSON.parse(str)
    rescue JSON::ParserError
      nil
    end

    def deep_symbolize(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), out| out[k.to_sym] = deep_symbolize(v) }
      when Array
        obj.map { |v| deep_symbolize(v) }
      else
        obj
      end
    end

    # Version bookkeeping is best-effort: a flaky adapter must never turn a
    # feature toggle into an exception. NotImplementedError is caught too — it
    # is what a custom adapter raises for primitives it has not implemented
    # (#delete_key, #next_sequence), and it is not a StandardError.
    def safely
      yield
    rescue StandardError, NotImplementedError
      nil
    end
  end
end
