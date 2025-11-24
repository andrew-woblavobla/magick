# frozen_string_literal: true

module Magick
  module Adapters
    class Memory < Base
      def initialize
        @store = {}
        @mutex = Mutex.new
        @ttl = {}
        @default_ttl = 3600 # 1 hour default TTL
      end

      def get(feature_name, key)
        # Fast path: avoid mutex if possible (use string keys directly)
        feature_name_str = feature_name.is_a?(String) ? feature_name : feature_name.to_s
        key_str = key.is_a?(String) ? key : key.to_s

        mutex.synchronize do
          cleanup_expired
          feature_data = store[feature_name_str]
          return nil unless feature_data

          value = feature_data[key_str]
          deserialize_value(value)
        end
      end

      def set(feature_name, key, value)
        mutex.synchronize do
          feature_name_str = feature_name.to_s
          store[feature_name_str] ||= {}
          store[feature_name_str][key.to_s] = serialize_value(value)
          update_ttl(feature_name_str)
        end
      end

      def delete(feature_name)
        mutex.synchronize do
          feature_name_str = feature_name.to_s
          store.delete(feature_name_str)
          ttl.delete(feature_name_str)
        end
      end

      def exists?(feature_name)
        mutex.synchronize do
          cleanup_expired
          store.key?(feature_name.to_s)
        end
      end

      def all_features
        mutex.synchronize do
          cleanup_expired
          store.keys
        end
      end

      def clear
        mutex.synchronize do
          @store = {}
          @ttl = {}
        end
      end

      def set_ttl(feature_name, seconds)
        mutex.synchronize do
          ttl[feature_name.to_s] = Time.now.to_i + seconds
        end
      end

      private

      attr_reader :store, :mutex, :ttl, :default_ttl

      def cleanup_expired
        now = Time.now.to_i
        expired_keys = ttl.select { |_key, expiry| expiry < now }.keys
        expired_keys.each do |key|
          store.delete(key)
          ttl.delete(key)
        end
      end

      def update_ttl(feature_name)
        ttl[feature_name] = Time.now.to_i + default_ttl
      end

      def serialize_value(value)
        case value
        when Hash, Array
          Marshal.dump(value)
        else
          value
        end
      end

      def deserialize_value(value)
        return nil if value.nil?

        case value
        when String
          # Try to unmarshal if it's a serialized hash/array
          begin
            Marshal.load(value)
          rescue StandardError
            value
          end
        else
          value
        end
      end
    end
  end
end
