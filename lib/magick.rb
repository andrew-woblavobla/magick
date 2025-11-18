# frozen_string_literal: true

require_relative 'magick/version'
require_relative 'magick/feature'
require_relative 'magick/adapters/base'
require_relative 'magick/adapters/memory'
require_relative 'magick/adapters/redis'
require_relative 'magick/adapters/registry'
require_relative 'magick/targeting/base'
require_relative 'magick/targeting/user'
require_relative 'magick/targeting/group'
require_relative 'magick/targeting/role'
require_relative 'magick/targeting/percentage'
require_relative 'magick/targeting/request_percentage'
require_relative 'magick/errors'

require_relative 'magick/audit_log'
require_relative 'magick/performance_metrics'
require_relative 'magick/export_import'
require_relative 'magick/versioning'
require_relative 'magick/circuit_breaker'
require_relative 'magick/testing_helpers'
require_relative 'magick/feature_dependency'
require_relative 'magick/config'

# Always load DSL - it will make itself available when Rails is detected
require_relative 'magick/dsl'

module Magick
  class << self
    attr_accessor :adapter_registry, :default_adapter, :performance_metrics, :audit_log, :versioning,
                  :warn_on_deprecated

    def configure(&block)
      @performance_metrics ||= PerformanceMetrics.new
      @audit_log ||= AuditLog.new
      @warn_on_deprecated ||= false

      # Support both old style and new DSL style
      return unless block_given?

      if block.arity == 0
        # New DSL style
        ConfigDSL.configure(&block)
      else
        # Old style
        yield self
      end
    end

    def [](feature_name)
      # Return registered feature if it exists, otherwise create new instance
      features[feature_name.to_s] || Feature.new(feature_name, adapter_registry || default_adapter_registry)
    end

    def features
      @features ||= {}
    end

    def register_feature(name, **options)
      feature = Feature.new(name, adapter_registry || default_adapter_registry, **options)
      features[name.to_s] = feature
      feature
    end

    def enabled?(feature_name, context = {})
      feature = features[feature_name.to_s] || self[feature_name]
      feature.enabled?(context)
    end

    # Reload a feature from the adapter (useful when feature is changed externally)
    def reload_feature(feature_name)
      feature = features[feature_name.to_s] || self[feature_name]
      feature.reload
    end

    def disabled?(feature_name, context = {})
      !enabled?(feature_name, context)
    end

    def exists?(feature_name)
      features.key?(feature_name.to_s) || (adapter_registry || default_adapter_registry).exists?(feature_name)
    end

    def bulk_enable(feature_names, context = {})
      feature_names.map do |name|
        feature = features[name.to_s] || self[name]
        feature.set_value(true) if feature.type == :boolean
        feature
      end
    end

    def bulk_disable(feature_names, context = {})
      feature_names.map do |name|
        feature = features[name.to_s] || self[name]
        feature.set_value(false) if feature.type == :boolean
        feature
      end
    end

    def export(format: :json)
      case format
      when :json
        ExportImport.export_json(features)
      when :hash
        ExportImport.export(features)
      else
        ExportImport.export(features)
      end
    end

    def import(data, format: :json)
      imported = ExportImport.import(data, adapter_registry || default_adapter_registry)
      imported.each { |name, feature| features[name] = feature }
      imported
    end

    def versioning
      @versioning ||= Versioning.new(adapter_registry || default_adapter_registry)
    end

    def reset!
      @features = {}
      @adapter_registry = nil
      @default_adapter = nil
      @performance_metrics&.clear!
    end

    private

    def default_adapter_registry
      @default_adapter_registry ||= begin
        memory_adapter = Adapters::Memory.new
        redis_adapter = begin
          Adapters::Redis.new if defined?(Redis)
        rescue AdapterError
          nil
        end
        Adapters::Registry.new(memory_adapter, redis_adapter)
      end
    end
  end
end
