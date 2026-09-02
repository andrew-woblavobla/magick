# frozen_string_literal: true

require 'json'

module Magick
  class ExportImport
    # Hard cap on the number of features accepted by a single import call.
    # Guards against DoS via an oversized payload and (combined with Admin UI
    # auth) stops an attacker from using import as a flag-replacement
    # primitive. Override with the MAGICK_MAX_IMPORT_FEATURES env var.
    DEFAULT_MAX_IMPORT_FEATURES = 10_000

    class ImportError < StandardError; end

    def self.max_import_features
      ENV.fetch('MAGICK_MAX_IMPORT_FEATURES', DEFAULT_MAX_IMPORT_FEATURES).to_i
    end

    def self.export(features_hash)
      result = features_hash.map do |_name, feature|
        feature.to_h
      end

      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.exported(format: :hash, feature_count: result.length)
      end

      result
    end

    def self.export_json(features_hash)
      result = JSON.pretty_generate(export(features_hash))

      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.exported(format: :json, feature_count: features_hash.length)
      end

      result
    end

    def self.import(data, adapter_registry)
      features = {}
      data = JSON.parse(data) if data.is_a?(String)
      list = Array(data)

      cap = max_import_features
      if list.size > cap
        raise ImportError,
              "Magick.import: refused to import #{list.size} features; limit is #{cap}. " \
              'Set MAGICK_MAX_IMPORT_FEATURES to override.'
      end

      list.each do |feature_data|
        unless feature_data.is_a?(Hash)
          raise ImportError, "Magick.import: each feature payload must be a Hash, got #{feature_data.class}"
        end

        name = fetch(feature_data, :name)
        next unless name

        targeting = fetch(feature_data, :targeting)
        targeting = {} unless targeting.is_a?(Hash)

        feature = build_feature(name, feature_data, adapter_registry)
        apply_value(feature, feature_data)
        apply_targeting(feature, targeting)
        apply_variants(feature, feature_data, targeting)
        apply_dependencies(feature, fetch(feature_data, :dependencies))

        features[name.to_s] = feature
      end

      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.imported(format: :json, feature_count: features.length)
      end

      features
    end

    def self.fetch(hash, key)
      # Must not use `||` — falsy legitimate values (false, 0, "") would
      # silently fall through to the string-key lookup (and then to nil).
      return hash[key] if hash.key?(key)

      string_key = key.to_s
      return hash[string_key] if hash.key?(string_key)

      nil
    end

    def self.build_feature(name, feature_data, adapter_registry)
      Feature.new(
        name,
        adapter_registry,
        type: (fetch(feature_data, :type) || :boolean).to_sym,
        status: (fetch(feature_data, :status) || :active).to_sym,
        default_value: fetch(feature_data, :default_value),
        description: fetch(feature_data, :description),
        display_name: fetch(feature_data, :display_name),
        group: fetch(feature_data, :group)
      )
    end

    def self.apply_value(feature, feature_data)
      value = fetch(feature_data, :value)
      feature.set_value(value) if !value.nil? && !(value.is_a?(String) && value.empty?)
    end

    def self.apply_targeting(feature, targeting)
      return unless targeting.is_a?(Hash)

      # Variants live under the internal :variants key of the targeting hash
      # but are not part of the targeting wire payload, so they are stripped
      # here and applied separately by apply_variants.
      payload = targeting.reject { |key, _| key.to_s == 'variants' }
      return if payload.empty?

      feature.replace_targeting(payload)
    rescue Magick::InvalidTargetingError => e
      raise ImportError, "Magick.import: invalid targeting for '#{feature.name}': #{e.message}"
    end

    # Variants are read from the top-level key, falling back to the
    # targeting hash for exports written by gem versions whose top-level
    # list was always empty. The payload is the imported feature's whole
    # state, so one without variants must not inherit the variants a
    # same-named feature already has in the target store.
    def self.apply_variants(feature, feature_data, targeting)
      source = Array(fetch(feature_data, :variants))
      source = Array(fetch(targeting, :variants)) if source.empty?

      list = source.filter_map do |variant|
        next unless variant.is_a?(Hash)

        v = variant.transform_keys(&:to_sym)
        next unless v[:name]

        { name: v[:name], value: v[:value], weight: v[:weight] }
      end

      list.empty? ? feature.clear_variants : feature.set_variants(list)
    end

    # A payload without a "dependencies" key leaves the feature's stored
    # prerequisites alone; an explicit list (including []) replaces them, so an
    # export taken after a dependency was removed re-applies that removal.
    def self.apply_dependencies(feature, deps)
      return if deps.nil?

      feature.replace_dependencies(deps)
    rescue ArgumentError => e
      raise ImportError, "Magick.import: invalid dependencies for '#{feature.name}': #{e.message}"
    end
  end
end
