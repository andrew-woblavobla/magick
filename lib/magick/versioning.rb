# frozen_string_literal: true

module Magick
  class Versioning
    class Version
      attr_reader :version, :feature_data, :timestamp, :created_by

      def initialize(version, feature_data, created_by: nil)
        @version = version
        @feature_data = feature_data
        @timestamp = Time.now
        @created_by = created_by
      end

      def to_h
        {
          version: version,
          feature_data: feature_data,
          timestamp: timestamp.iso8601,
          created_by: created_by
        }
      end
    end

    def initialize(adapter_registry)
      @adapter_registry = adapter_registry
      @versions = {}
      @mutex = Mutex.new
    end

    def save_version(feature_name, version: nil, created_by: nil)
      feature = Magick.features[feature_name.to_s] || Magick[feature_name]
      version ||= next_version(feature_name)
      version_data = Version.new(version, feature.to_h, created_by: created_by)

      @mutex.synchronize do
        @versions[feature_name.to_s] ||= []
        @versions[feature_name.to_s] << version_data
        # Store in adapter
        @adapter_registry.set(feature_name, "version_#{version}", version_data.to_h)
      end

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.version_saved(feature_name, version: version, created_by: created_by)
      end

      version_data
    end

    def rollback(feature_name, version)
      versions = get_versions(feature_name)
      target_version = versions.find { |v| v.version == version }
      return false unless target_version

      feature = Magick.features[feature_name.to_s] || Magick[feature_name]
      feature_data = target_version.feature_data

      # Restore feature state
      feature.set_value(feature_data[:value]) if feature_data[:value]
      feature.set_status(feature_data[:status]) if feature_data[:status]

      # Restore targeting
      feature_data[:targeting]&.each do |type, values|
        Array(values).each do |value|
          case type.to_sym
          when :user
            feature.enable_for_user(value)
          when :group
            feature.enable_for_group(value)
          when :role
            feature.enable_for_role(value)
          end
        end
      end

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.rollback(feature_name, version: version)
      end

      true
    end

    def get_versions(feature_name)
      @versions[feature_name.to_s] || []
    end

    private

    def next_version(feature_name)
      versions = get_versions(feature_name)
      versions.empty? ? 1 : versions.last.version + 1
    end
  end
end
