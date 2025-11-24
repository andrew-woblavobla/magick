# frozen_string_literal: true

module Magick
  module TestingHelpers
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def with_feature_enabled(feature_name)
        feature = Magick.features[feature_name.to_s] || Magick[feature_name]
        original_value = feature.value
        feature.set_value(true)
        yield
      ensure
        feature.set_value(original_value)
      end

      def with_feature_disabled(feature_name)
        feature = Magick.features[feature_name.to_s] || Magick[feature_name]
        original_value = feature.value
        feature.set_value(false)
        yield
      ensure
        feature.set_value(original_value)
      end

      def with_feature_value(feature_name, value)
        feature = Magick.features[feature_name.to_s] || Magick[feature_name]
        original_value = feature.value
        feature.set_value(value)
        yield
      ensure
        feature.set_value(original_value)
      end
    end
  end
end

# Include in RSpec
if defined?(RSpec)
  RSpec.configure do |config|
    config.include Magick::TestingHelpers
  end
end
