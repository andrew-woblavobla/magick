# frozen_string_literal: true

require 'json'

module Magick
  class ExportImport
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

      Array(data).each do |feature_data|
        name = fetch(feature_data, :name)
        next unless name

        feature = build_feature(name, feature_data, adapter_registry)
        apply_value(feature, feature_data)
        apply_targeting(feature, fetch(feature_data, :targeting) || {})
        apply_variants(feature, fetch(feature_data, :variants) || [])
        apply_dependencies(feature, fetch(feature_data, :dependencies) || [])

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

    # rubocop:disable Metrics/MethodLength
    # rubocop:disable Metrics/CyclomaticComplexity
    def self.apply_targeting(feature, targeting)
      targeting.each do |type, values|
        case type.to_sym
        when :user, :users
          Array(values).each { |v| feature.enable_for_user(v) }
        when :excluded_users
          Array(values).each { |v| feature.exclude_user(v) }
        when :group, :groups
          Array(values).each { |v| feature.enable_for_group(v) }
        when :excluded_groups
          Array(values).each { |v| feature.exclude_group(v) }
        when :role, :roles
          Array(values).each { |v| feature.enable_for_role(v) }
        when :excluded_roles
          Array(values).each { |v| feature.exclude_role(v) }
        when :tag, :tags
          Array(values).each { |v| feature.enable_for_tag(v) }
        when :excluded_tags
          Array(values).each { |v| feature.exclude_tag(v) }
        when :ip_address, :ip_addresses
          feature.enable_for_ip_addresses(Array(values))
        when :excluded_ip_addresses
          feature.exclude_ip_addresses(Array(values))
        when :percentage_users
          feature.enable_percentage_of_users(values)
        when :percentage_requests
          feature.enable_percentage_of_requests(values)
        when :date_range
          range = values.is_a?(Hash) ? values.transform_keys(&:to_sym) : values
          feature.enable_for_date_range(range[:start], range[:end]) if range.is_a?(Hash) && range[:start] && range[:end]
        when :custom_attributes
          apply_custom_attributes(feature, values)
        end
      end
    end
    # rubocop:enable Metrics/MethodLength
    # rubocop:enable Metrics/CyclomaticComplexity

    def self.apply_custom_attributes(feature, values)
      return unless values.is_a?(Hash)

      values.each do |attr, rule|
        rule_h = rule.is_a?(Hash) ? rule.transform_keys(&:to_sym) : {}
        next unless rule_h[:values]

        feature.enable_for_custom_attribute(attr, rule_h[:values], operator: (rule_h[:operator] || :equals).to_sym)
      end
    end

    def self.apply_variants(feature, variants)
      return unless feature.respond_to?(:add_variant)

      Array(variants).each do |v|
        h = v.is_a?(Hash) ? v.transform_keys(&:to_sym) : {}
        next unless h[:name]

        feature.add_variant(h[:name], weight: h[:weight], value: h[:value])
      end
    end

    def self.apply_dependencies(feature, deps)
      list = Array(deps).map(&:to_s)
      return if list.empty?

      feature.instance_variable_set(:@dependencies, list)
    end
  end
end
