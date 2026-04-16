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

      # Bulk set multiple keys for a feature in one call.
      # Subclasses MUST implement this — a no-op default silently drops
      # bulk writes, which is why this used to cause hard-to-diagnose lost
      # updates for custom adapters (audit P2-Co6).
      def set_all_data(feature_name, data_hash)
        raise NotImplementedError,
              "#{self.class} must implement #set_all_data (feature=#{feature_name}, keys=#{data_hash.keys.inspect})"
      end
    end
  end
end
