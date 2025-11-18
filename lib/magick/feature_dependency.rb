# frozen_string_literal: true

module Magick
  class FeatureDependency
    def self.check(feature_name, context = {})
      feature = Magick.features[feature_name.to_s] || Magick[feature_name]
      dependencies = feature.instance_variable_get(:@dependencies) || []

      dependencies.all? do |dep_name|
        Magick.enabled?(dep_name, context)
      end
    end

    def self.add_dependency(feature_name, dependency_name)
      feature = Magick.features[feature_name.to_s] || Magick[feature_name]
      dependencies = feature.instance_variable_get(:@dependencies) || []
      dependencies << dependency_name.to_s unless dependencies.include?(dependency_name.to_s)
      feature.instance_variable_set(:@dependencies, dependencies)
    end

    def self.remove_dependency(feature_name, dependency_name)
      feature = Magick.features[feature_name.to_s] || Magick[feature_name]
      dependencies = feature.instance_variable_get(:@dependencies) || []
      dependencies.delete(dependency_name.to_s)
      feature.instance_variable_set(:@dependencies, dependencies)
    end
  end
end
