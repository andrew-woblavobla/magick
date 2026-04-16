# frozen_string_literal: true

require 'json'

module Magick
  module Adapters
    class Redis < Base
      def initialize(redis_client = nil)
        @redis = redis_client || default_redis_client
        @namespace = 'magick:features'
        raise AdapterError, 'Redis client is required' unless @redis
      rescue StandardError => e
        raise AdapterError, "Failed to initialize Redis adapter: #{e.message}"
      end

      def get(feature_name, key)
        value = redis.hget(key_for(feature_name), key.to_s)
        deserialize_value(value)
      rescue StandardError => e
        raise AdapterError, "Failed to get from Redis: #{e.message}"
      end

      def set(feature_name, key, value)
        redis.hset(key_for(feature_name), key.to_s, serialize_value(value))
      rescue StandardError => e
        raise AdapterError, "Failed to set in Redis: #{e.message}"
      end

      def delete(feature_name)
        redis.del(key_for(feature_name))
      rescue StandardError => e
        raise AdapterError, "Failed to delete from Redis: #{e.message}"
      end

      def exists?(feature_name)
        redis.exists?(key_for(feature_name))
      rescue StandardError => e
        raise AdapterError, "Failed to check existence in Redis: #{e.message}"
      end

      def all_features
        keys = scan_keys
        keys.map { |key| key.sub("#{namespace}:", '') }
      rescue StandardError => e
        raise AdapterError, "Failed to get all features from Redis: #{e.message}"
      end

      def get_all_data(feature_name)
        raw = redis.hgetall(key_for(feature_name))
        return {} if raw.nil? || raw.empty?

        raw.each_with_object({}) do |(k, v), result|
          result[k.to_s] = deserialize_value(v)
        end
      rescue StandardError => e
        raise AdapterError, "Failed to get all data from Redis: #{e.message}"
      end

      def load_all_features_data
        keys = scan_keys
        return {} if keys.empty?

        # Pipeline all HGETALL calls to avoid N+1 round-trips
        raw_results = redis.pipelined do |pipeline|
          keys.each { |key| pipeline.hgetall(key) }
        end

        result = {}
        keys.each_with_index do |key, idx|
          feature_name = key.sub("#{namespace}:", '')
          raw = raw_results[idx]
          next if raw.nil? || raw.empty?

          feature_data = {}
          raw.each do |k, v|
            feature_data[k.to_s] = deserialize_value(v)
          end
          result[feature_name] = feature_data
        end
        result
      rescue StandardError => e
        raise AdapterError, "Failed to load all features from Redis: #{e.message}"
      end

      def set_all_data(feature_name, data_hash)
        return if data_hash.nil? || data_hash.empty?

        serialized = {}
        data_hash.each do |key, value|
          serialized[key.to_s] = serialize_value(value)
        end
        redis.mapped_hmset(key_for(feature_name), serialized)
      rescue StandardError => e
        raise AdapterError, "Failed to set all data in Redis: #{e.message}"
      end

      # Public accessor for the underlying Redis client
      def client
        @redis
      end

      private

      attr_reader :redis, :namespace

      # Use SCAN instead of KEYS to avoid blocking Redis.
      # A mid-scan timeout would otherwise lose the cursor; retry once with
      # exponential backoff before surfacing the error to the caller.
      def scan_keys
        pattern = "#{namespace}:*"
        keys = []
        cursor = '0'
        retries = 0
        loop do
          begin
            cursor, batch = redis.scan(cursor, match: pattern, count: 100)
          rescue StandardError => e
            raise if retries >= 1

            retries += 1
            sleep(0.05 * retries)
            retry
          end
          keys.concat(batch)
          break if cursor == '0'
        end
        keys
      end

      def key_for(feature_name)
        "#{namespace}:#{feature_name}"
      end

      def default_redis_client
        return nil unless defined?(Redis)

        require 'redis'
        ::Redis.new
      rescue StandardError
        nil
      end

      def serialize_value(value)
        case value
        when Hash, Array
          JSON.generate(value)
        when true
          'true'
        when false
          'false'
        else
          value.to_s
        end
      end

      def deserialize_value(value)
        return nil if value.nil?

        if value == 'true'
          true
        elsif value == 'false'
          false
        elsif value.is_a?(String) && value.start_with?('{', '[')
          begin
            JSON.parse(value)
          rescue JSON::ParserError
            value
          end
        else
          value
        end
      end
    end
  end
end
