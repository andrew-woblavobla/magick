# frozen_string_literal: true

module Magick
  module Rails
    module Events
      # Check if Rails 8.1+ structured events are available
      def self.rails81?
        defined?(Rails) && Rails.respond_to?(:event) && Rails.event.respond_to?(:notify)
      end

      # Event names (using Rails 8.1 structured event format)
      EVENT_PREFIX = 'magick.feature_flag'

      EVENTS = {
        changed: "#{EVENT_PREFIX}.changed",
        enabled: "#{EVENT_PREFIX}.enabled",
        disabled: "#{EVENT_PREFIX}.disabled",
        dependency_added: "#{EVENT_PREFIX}.dependency_added",
        dependency_removed: "#{EVENT_PREFIX}.dependency_removed",
        variant_set: "#{EVENT_PREFIX}.variant_set",
        variant_selected: "#{EVENT_PREFIX}.variant_selected",
        targeting_added: "#{EVENT_PREFIX}.targeting_added",
        targeting_removed: "#{EVENT_PREFIX}.targeting_removed",
        version_saved: "#{EVENT_PREFIX}.version_saved",
        rollback: "#{EVENT_PREFIX}.rollback",
        exported: "#{EVENT_PREFIX}.exported",
        imported: "#{EVENT_PREFIX}.imported",
        audit_logged: "#{EVENT_PREFIX}.audit_logged",
        usage_tracked: "#{EVENT_PREFIX}.usage_tracked",
        deprecated_warning: "#{EVENT_PREFIX}.deprecated_warning"
      }.freeze

      def self.notify(event_name, payload = {})
        return unless rails81?

        event_name_str = EVENTS[event_name] || event_name.to_s
        Rails.event.notify(event_name_str, payload)
      end

      # Backward compatibility alias
      def self.rails8?
        rails81?
      end

      # Feature flag changed (value, status, etc.)
      def self.feature_changed(feature_name, changes:, user_id: nil, **metadata)
        notify(:changed, {
          feature_name: feature_name.to_s,
          changes: changes,
          user_id: user_id,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Feature enabled
      def self.feature_enabled(feature_name, context: {}, **metadata)
        notify(:enabled, {
          feature_name: feature_name.to_s,
          context: context,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Feature disabled
      def self.feature_disabled(feature_name, context: {}, **metadata)
        notify(:disabled, {
          feature_name: feature_name.to_s,
          context: context,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Dependency added
      def self.dependency_added(feature_name, dependency_name, **metadata)
        notify(:dependency_added, {
          feature_name: feature_name.to_s,
          dependency_name: dependency_name.to_s,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Dependency removed
      def self.dependency_removed(feature_name, dependency_name, **metadata)
        notify(:dependency_removed, {
          feature_name: feature_name.to_s,
          dependency_name: dependency_name.to_s,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Variants set
      def self.variant_set(feature_name, variants:, **metadata)
        notify(:variant_set, {
          feature_name: feature_name.to_s,
          variants: variants.is_a?(Array) ? variants.map(&:to_h) : variants,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Variant selected
      def self.variant_selected(feature_name, variant_name:, context: {}, **metadata)
        notify(:variant_selected, {
          feature_name: feature_name.to_s,
          variant_name: variant_name.to_s,
          context: context,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Targeting added
      def self.targeting_added(feature_name, targeting_type:, targeting_value:, **metadata)
        notify(:targeting_added, {
          feature_name: feature_name.to_s,
          targeting_type: targeting_type.to_s,
          targeting_value: targeting_value,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Targeting removed
      def self.targeting_removed(feature_name, targeting_type:, targeting_value: nil, **metadata)
        notify(:targeting_removed, {
          feature_name: feature_name.to_s,
          targeting_type: targeting_type.to_s,
          targeting_value: targeting_value,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Version saved
      def self.version_saved(feature_name, version:, created_by: nil, **metadata)
        notify(:version_saved, {
          feature_name: feature_name.to_s,
          version: version,
          created_by: created_by,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Rollback performed
      def self.rollback(feature_name, version:, **metadata)
        notify(:rollback, {
          feature_name: feature_name.to_s,
          version: version,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Export performed
      def self.exported(format:, feature_count:, **metadata)
        notify(:exported, {
          format: format.to_s,
          feature_count: feature_count,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Import performed
      def self.imported(format:, feature_count:, **metadata)
        notify(:imported, {
          format: format.to_s,
          feature_count: feature_count,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Audit log entry created
      def self.audit_logged(feature_name, action:, user_id: nil, changes: {}, **metadata)
        notify(:audit_logged, {
          feature_name: feature_name.to_s,
          action: action.to_s,
          user_id: user_id,
          changes: changes,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Usage tracked
      def self.usage_tracked(feature_name, operation:, duration:, success: true, **metadata)
        notify(:usage_tracked, {
          feature_name: feature_name.to_s,
          operation: operation.to_s,
          duration: duration,
          success: success,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end

      # Deprecation warning
      def self.deprecated_warning(feature_name, **metadata)
        notify(:deprecated_warning, {
          feature_name: feature_name.to_s,
          timestamp: Time.now.iso8601,
          **metadata
        })
      end
    end
  end
end
