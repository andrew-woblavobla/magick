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
    end
  end
end
