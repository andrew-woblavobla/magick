# frozen_string_literal: true

require 'json'

module Magick
  module Adapters
    class Redis < Base
      # redis-rb defaults every timeout to 5s. A feature-flag lookup is on the
      # hot path of a request, and a Redis that black-holes packets (a dropped
      # route, a hung box) does not refuse the connection — it just never
      # answers — so an untimed client pins the request thread for those 5s
      # while the circuit breaker never gets an error to count. One second is
      # already an eternity for a HGET against a local Redis; past that we
      # would rather fall through to the next adapter.
      DEFAULT_TIMEOUTS = {
        connect_timeout: 1.0,
        read_timeout: 1.0,
        write_timeout: 1.0
      }.freeze

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
        fetch_features_data(scan_keys)
      rescue StandardError => e
        raise AdapterError, "Failed to load all features from Redis: #{e.message}"
      end

      # SCAN does the narrowing server-side; the Ruby check that follows guards
      # against a glob metacharacter in the prefix widening the match.
      def load_features_data_with_prefix(prefix)
        prefix = prefix.to_s
        keys = scan_keys(match: "#{glob_escape(prefix)}*")
        fetch_features_data(keys.select { |key| feature_name_from(key).start_with?(prefix) })
      rescue StandardError => e
        raise AdapterError, "Failed to load prefixed features from Redis: #{e.message}"
      end

      # SCAN has no negative MATCH, so the keys are filtered by name before the
      # pipeline runs. Only the names travel; the excluded hashes are never
      # fetched, which is the whole point — the version archive is the bulk of
      # the payload a preload would otherwise pull down.
      def load_features_data_without_prefixes(prefixes)
        prefixes = Array(prefixes).map(&:to_s)
        keys = scan_keys.reject do |key|
          name = feature_name_from(key)
          prefixes.any? { |prefix| name.start_with?(prefix) }
        end
        fetch_features_data(keys)
      rescue StandardError => e
        raise AdapterError, "Failed to load unprefixed features from Redis: #{e.message}"
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

      def delete_key(feature_name, key)
        redis.hdel(key_for(feature_name), key.to_s).to_i.positive?
      rescue StandardError => e
        raise AdapterError, "Failed to delete key from Redis: #{e.message}"
      end

      # Server-side allocation: HSETNX seeds the counter only if it is missing
      # and HINCRBY is atomic, so every process sharing this Redis is handed a
      # different number no matter how their calls interleave.
      def next_sequence(feature_name, key, floor: 0)
        redis_key = key_for(feature_name)
        field = key.to_s
        floor = floor.to_i

        redis.hsetnx(redis_key, field, floor)
        value = redis.hincrby(redis_key, field, 1).to_i
        return value if value > floor

        # The counter trailed the history the caller can see (a dump restored
        # without it, or entries written before there was one). Jump it past the
        # floor with another atomic increment: concurrent callers doing the same
        # still come away with distinct numbers.
        redis.hincrby(redis_key, field, (floor - value) + 1).to_i
      rescue StandardError => e
        raise AdapterError, "Failed to allocate sequence in Redis: #{e.message}"
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
      def scan_keys(match: '*')
        pattern = "#{namespace}:#{match}"
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

      def feature_name_from(key)
        key.sub("#{namespace}:", '')
      end

      # SCAN MATCH takes a glob, so a prefix containing *, ?, [ or a
      # backslash would match keys the caller did not ask for.
      def glob_escape(pattern)
        pattern.gsub(/[\\*?\[\]]/) { |char| "\\#{char}" }
      end

      # One pipelined HGETALL per key, so a bulk load costs a single round-trip
      # rather than one per feature.
      def fetch_features_data(keys)
        return {} if keys.empty?

        raw_results = redis.pipelined do |pipeline|
          keys.each { |key| pipeline.hgetall(key) }
        end

        result = {}
        keys.each_with_index do |key, idx|
          raw = raw_results[idx]
          next if raw.nil? || raw.empty?

          feature_data = {}
          raw.each do |k, v|
            feature_data[k.to_s] = deserialize_value(v)
          end
          result[feature_name_from(key)] = feature_data
        end
        result
      end

      def default_redis_client
        return nil unless defined?(Redis)

        require 'redis'
        ::Redis.new(**DEFAULT_TIMEOUTS)
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
