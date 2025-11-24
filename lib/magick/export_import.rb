# frozen_string_literal: true

require 'json'

module Magick
  class ExportImport
    def self.export(features_hash)
      result = features_hash.map do |_name, feature|
        feature.to_h
      end

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.exported(format: :hash, feature_count: result.length)
      end

      result
    end

    def self.export_json(features_hash)
      result = JSON.pretty_generate(export(features_hash))

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.exported(format: :json, feature_count: features_hash.length)
      end

      result
    end

    def self.import(data, adapter_registry)
      features = {}
      data = JSON.parse(data) if data.is_a?(String)

      Array(data).each do |feature_data|
        name = feature_data['name'] || feature_data[:name]
        next unless name

        feature = Feature.new(
          name,
          adapter_registry,
          type: (feature_data['type'] || feature_data[:type] || :boolean).to_sym,
          status: (feature_data['status'] || feature_data[:status] || :active).to_sym,
          default_value: feature_data['default_value'] || feature_data[:default_value],
          description: feature_data['description'] || feature_data[:description]
        )

        if feature_data['value'] || feature_data[:value]
          feature.set_value(feature_data['value'] || feature_data[:value])
        end

        # Import targeting
        if feature_data['targeting'] || feature_data[:targeting]
          targeting = feature_data['targeting'] || feature_data[:targeting]
          targeting.each do |type, values|
            Array(values).each do |value|
              case type.to_sym
              when :user
                feature.enable_for_user(value)
              when :group
                feature.enable_for_group(value)
              when :role
                feature.enable_for_role(value)
              when :percentage_users
                feature.enable_percentage_of_users(value)
              when :percentage_requests
                feature.enable_percentage_of_requests(value)
              end
            end
          end
        end

        features[name.to_s] = feature
      end

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.imported(format: format, feature_count: features.length)
      end

      features
    end
  end
end
