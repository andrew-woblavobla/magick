# frozen_string_literal: true

require 'json'

module Magick
  module Adapters
    class Memory < Base
      CLEANUP_INTERVAL = 30 # seconds between cleanup sweeps

      def initialize
        @store = {}
        @mutex = Mutex.new
        @ttl = {}
        @default_ttl = 3600 # 1 hour default TTL
        @last_cleanup = Time.now.to_i
      end

      def get(feature_name, key)
        feature_name_str = feature_name.is_a?(String) ? feature_name : feature_name.to_s
        key_str = key.is_a?(String) ? key : key.to_s

        mutex.synchronize do
          cleanup_expired_if_needed
          feature_data = store[feature_name_str]
          return nil unless feature_data

          value = feature_data[key_str]
          deserialize_value(value)
        end
      end

      def set(feature_name, key, value)
        mutex.synchronize do
          cleanup_expired_if_needed
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
          cleanup_expired_if_needed
          store.key?(feature_name.to_s)
        end
      end

      def all_features
        mutex.synchronize do
          cleanup_expired_if_needed
          store.keys
        end
      end

      def get_all_data(feature_name)
        feature_name_str = feature_name.to_s
        mutex.synchronize do
          cleanup_expired_if_needed
          feature_data = store[feature_name_str]
          return {} unless feature_data

          feature_data.each_with_object({}) do |(k, v), result|
            result[k] = deserialize_value(v)
          end
        end
      end

      def load_all_features_data
        mutex.synchronize do
          cleanup_expired_if_needed
          result = {}
          store.each do |feature_name, feature_data|
            deserialized = {}
            feature_data.each do |k, v|
              deserialized[k] = deserialize_value(v)
            end
            result[feature_name] = deserialized
          end
          result
        end
      end

      # Bulk set all data for a feature (used by preloading)
      def set_all_data(feature_name, data_hash)
        mutex.synchronize do
          cleanup_expired_if_needed
          feature_name_str = feature_name.to_s
          store[feature_name_str] ||= {}
          data_hash.each do |key, value|
            store[feature_name_str][key.to_s] = serialize_value(value)
          end
          update_ttl(feature_name_str)
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

      def cleanup_expired_if_needed
        now = Time.now.to_i
        return if now - @last_cleanup < CLEANUP_INTERVAL

        @last_cleanup = now
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
          JSON.generate(value)
        else
          value
        end
      end

      def deserialize_value(value)
        return nil if value.nil?

        case value
        when String
          # Only attempt JSON parse on strings that look like JSON objects/arrays
          if value.start_with?('{', '[')
            begin
              JSON.parse(value)
            rescue JSON::ParserError
              value
            end
          else
            value
          end
        else
          value
        end
      end
    end
  end
end
