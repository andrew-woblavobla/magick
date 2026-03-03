# frozen_string_literal: true

module Magick
  module Adapters
    class Base
      def get(feature_name, key)
        raise NotImplementedError, "#{self.class} must implement #get"
      end

      def set(feature_name, key, value)
        raise NotImplementedError, "#{self.class} must implement #set"
      end

      def delete(feature_name)
        raise NotImplementedError, "#{self.class} must implement #delete"
      end

      def exists?(feature_name)
        raise NotImplementedError, "#{self.class} must implement #exists?"
      end

      def all_features
        raise NotImplementedError, "#{self.class} must implement #all_features"
      end

      # Load all keys for a single feature in one call (override for efficiency)
      def get_all_data(feature_name)
        {}
      end

      # Bulk load all features' data in one call (override for efficiency)
      def load_all_features_data
        {}
      end

      # Bulk set multiple keys for a feature in one call (override for efficiency)
      def set_all_data(_feature_name, _data_hash)
        # Default: no-op, subclasses override
      end
    end
  end
end
