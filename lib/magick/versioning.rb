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
      # Process-local cache of the hot window, rehydrated lazily from the
      # adapters so history survives restarts and is shared across containers.
      @hot = {}
      @mutex = Mutex.new
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
      hot = @mutex.synchronize { hot_window(name).dup }
      return hot unless all

      older = archive_versions(name).reject { |a| hot.any? { |h| h.version == a.version } }
      (older + hot).sort_by(&:version)
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

    def append(name, snapshot, version: nil, created_by: nil, action: nil)
      entry = @mutex.synchronize do
        window = hot_window(name)
        resolved = version || (window.last ? window.last.version + 1 : 1)
        record = Version.new(resolved, snapshot, created_by: created_by, action: action)
        window << record
        window.shift while window.size > @max_versions
        persist_hot_window(name, window)
        persist_archive(name, record)
        record
      end

      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.version_saved(name, version: entry.version, created_by: created_by)
      end

      entry
    end

    # Callers must hold @mutex.
    def hot_window(name)
      @hot[name] ||= load_hot_window(name)
    end

    def load_hot_window(name)
      raw = read_hot_list(name)
      raw = read_archive_tail(name) if raw.nil? || raw.empty?
      Array(raw).filter_map { |h| rehydrate(h) }.sort_by(&:version).last(@max_versions)
    end

    def read_hot_list(name)
      hot_adapters.each do |adapter|
        list = safely { adapter.get(store_name(name), 'versions') }
        list = parse_json(list) if list.is_a?(String)
        return list if list.is_a?(Array) && !list.empty?
      end
      nil
    end

    # Seed the hot window from the archive when memory/Redis are empty
    # (fresh boot, Redis flush) so version numbering continues, not restarts.
    def read_archive_tail(name)
      adapter = archive_adapter
      return nil unless adapter

      data = safely { adapter.get_all_data(store_name(name)) }
      return nil unless data.is_a?(Hash)

      data.filter_map { |key, value| value if key.to_s.start_with?('version_') }
    end

    def archive_versions(name)
      adapter = archive_adapter
      return [] unless adapter

      data = safely { adapter.get_all_data(store_name(name)) }
      return [] unless data.is_a?(Hash)

      data.filter_map { |key, value| rehydrate(value) if key.to_s.start_with?('version_') }.sort_by(&:version)
    end

    def persist_hot_window(name, window)
      payload = window.map(&:to_h)
      hot_adapters.each do |adapter|
        safely { adapter.set(store_name(name), 'versions', payload) }
      end
    end

    def persist_archive(name, entry)
      adapter = archive_adapter
      return unless adapter

      safely { adapter.set(store_name(name), "version_#{entry.version}", entry.to_h) }
    end

    def find_version(feature_name, version)
      name = feature_name.to_s
      hot = @mutex.synchronize { hot_window(name).dup }
      found = hot.find { |v| v.version == version }
      return found if found

      adapter = archive_adapter
      return nil unless adapter

      raw = safely { adapter.get(store_name(name), "version_#{version}") }
      raw ? rehydrate(raw) : nil
    end

    # Hot window lives in memory + Redis (capped); the ActiveRecord adapter
    # keeps the unlimited archive, one version_<n> key per entry.
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

    def store_name(name)
      "#{STORE_PREFIX}#{name}"
    end

    def rehydrate(raw)
      raw = parse_json(raw) if raw.is_a?(String)
      return nil unless raw.is_a?(Hash)

      data = deep_symbolize(raw)
      timestamp = data[:timestamp]
      timestamp = safely { Time.parse(timestamp) } if timestamp.is_a?(String)
      Version.new(
        data[:version],
        data[:feature_data] || {},
        created_by: data[:created_by],
        action: data[:action],
        timestamp: timestamp
      )
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
    # feature toggle into an exception.
    def safely
      yield
    rescue StandardError
      nil
    end
  end
end
