# frozen_string_literal: true

module Magick
  class AuditLog
    class Entry
      attr_reader :feature_name, :action, :user_id, :timestamp, :changes, :metadata

      def initialize(feature_name, action, user_id: nil, changes: {}, metadata: {})
        @feature_name = feature_name.to_s
        @action = action.to_s
        @user_id = user_id
        @timestamp = Time.now
        @changes = changes
        @metadata = metadata
      end

      def to_h
        {
          feature_name: feature_name,
          action: action,
          user_id: user_id,
          timestamp: timestamp.iso8601,
          changes: changes,
          metadata: metadata
        }
      end
    end

    DEFAULT_MAX_ENTRIES = 10_000

    def initialize(adapter = nil, max_entries: DEFAULT_MAX_ENTRIES)
      @adapter = adapter || default_adapter
      @logs = []
      @max_entries = max_entries.to_i.positive? ? max_entries.to_i : DEFAULT_MAX_ENTRIES
      @mutex = Mutex.new
    end

    attr_reader :max_entries

    def log(feature_name, action, user_id: nil, changes: {}, metadata: {})
      entry = Entry.new(feature_name, action, user_id: user_id, changes: changes, metadata: metadata)
      @mutex.synchronize do
        @logs << entry
        # Cap in-memory ring; older entries fall out once we cross the limit.
        # This keeps long-running processes from growing @logs unboundedly.
        @logs.shift while @logs.size > @max_entries
        @adapter.append(entry) if @adapter.respond_to?(:append)
      end

      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.audit_logged(feature_name, action: action, user_id: user_id, changes: changes, **metadata)
      end

      entry
    end

    def entries(feature_name: nil, limit: 100)
      snapshot = @mutex.synchronize { @logs.dup }
      snapshot = snapshot.select { |e| e.feature_name == feature_name.to_s } if feature_name
      snapshot.last(limit)
    end

    def size
      @mutex.synchronize { @logs.size }
    end

    private

    def default_adapter
      # Default to in-memory storage
      Class.new do
        def append(_entry); end
      end.new
    end
  end
end
