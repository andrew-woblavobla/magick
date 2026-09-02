# frozen_string_literal: true

module Magick
  module Adapters
    class ActiveRecord < Base
      def initialize(model_class: nil)
        @model_class = model_class || default_model_class
        # Cache AR version check once at init time (hot path optimization)
        ar_major = ::ActiveRecord::VERSION::MAJOR
        ar_minor = ::ActiveRecord::VERSION::MINOR
        @use_json = ar_major >= 8 || (ar_major == 7 && ar_minor >= 1)
        # Verify table exists - raise clear error if it doesn't
        unless @model_class.table_exists?
          raise AdapterError, "Table 'magick_features' does not exist. Please run: rails generate magick:active_record && rails db:migrate"
        end
      rescue StandardError => e
        raise AdapterError, "Failed to initialize ActiveRecord adapter: #{e.message}"
      end

      def get(feature_name, key)
        feature_name_str = feature_name.to_s
        record = @model_class.find_by(feature_name: feature_name_str)
        return nil unless record

        # Handle both Hash (from serialize) and Hash/JSON (from attribute :json)
        data = record.data || {}
        value = data.is_a?(Hash) ? data[key.to_s] : nil
        deserialize_value(value)
      rescue StandardError => e
        raise AdapterError, "Failed to get from ActiveRecord: #{e.message}"
      end

      def set(feature_name, key, value)
        feature_name_str = feature_name.to_s
        retries = 5
        begin
          @model_class.transaction do
            record = @model_class.lock.find_or_create_by!(feature_name: feature_name_str)
            data = record.data || {}
            data = {} unless data.is_a?(Hash)
            data[key.to_s] = serialize_value(value)
            record.update!(data: data, updated_at: defined?(Time.current) ? Time.current : Time.now)
          end
        rescue ::ActiveRecord::StatementInvalid, ::ActiveRecord::ConnectionTimeoutError => e
          # SQLite busy/locked errors - retry with linear backoff
          if (e.message.include?('database is locked') || e.message.include?('busy') || e.message.include?('timeout')) && retries > 0
            retries -= 1
            sleep(0.01 * (6 - retries))
            retry
          end
          raise AdapterError, "Failed to set in ActiveRecord: #{e.message}"
        rescue StandardError => e
          raise AdapterError, "Failed to set in ActiveRecord: #{e.message}"
        end
      end

      def delete(feature_name)
        feature_name_str = feature_name.to_s
        retries = 5
        begin
          @model_class.where(feature_name: feature_name_str).destroy_all
        rescue ::ActiveRecord::StatementInvalid, ::ActiveRecord::ConnectionTimeoutError => e
          # SQLite busy/locked errors - retry with exponential backoff
          if (e.message.include?('database is locked') || e.message.include?('busy') || e.message.include?('timeout')) && retries > 0
            retries -= 1
            sleep(0.01 * (6 - retries)) # Exponential backoff: 0.01, 0.02, 0.03, 0.04, 0.05
            retry
          end
          raise AdapterError, "Failed to delete from ActiveRecord: #{e.message}"
        rescue StandardError => e
          raise AdapterError, "Failed to delete from ActiveRecord: #{e.message}"
        end
      end

      def exists?(feature_name)
        @model_class.exists?(feature_name: feature_name.to_s)
      rescue StandardError => e
        raise AdapterError, "Failed to check existence in ActiveRecord: #{e.message}"
      end

      def all_features
        @model_class.pluck(:feature_name).uniq
      rescue StandardError => e
        raise AdapterError, "Failed to get all features from ActiveRecord: #{e.message}"
      end

      def get_all_data(feature_name)
        record = @model_class.find_by(feature_name: feature_name.to_s)
        return {} unless record

        data = record.data || {}
        return {} unless data.is_a?(Hash)

        data.each_with_object({}) do |(k, v), result|
          result[k.to_s] = deserialize_value(v)
        end
      rescue StandardError => e
        raise AdapterError, "Failed to get all data from ActiveRecord: #{e.message}"
      end

      def load_all_features_data
        collect_features_data(@model_class.all)
      rescue StandardError => e
        raise AdapterError, "Failed to load all features from ActiveRecord: #{e.message}"
      end

      # Prefix filtering happens in SQL so the rows outside the caller's
      # namespace are never read at all — the point being that a boot-time
      # preload must not drag the version archive out of the database. The
      # Ruby-side check is kept as well: LIKE is case-insensitive under some
      # MySQL collations, so the query may match more than the caller asked for
      # (never less, since the pattern is escaped).
      def load_features_data_with_prefix(prefix)
        prefix = prefix.to_s
        collect_features_data(@model_class.where(*like_prefix_condition(prefix))) do |feature_name|
          feature_name.start_with?(prefix)
        end
      rescue StandardError => e
        raise AdapterError, "Failed to load prefixed features from ActiveRecord: #{e.message}"
      end

      def load_features_data_without_prefixes(prefixes)
        prefixes = Array(prefixes).map(&:to_s)
        scope = prefixes.reduce(@model_class.all) { |rel, prefix| rel.where.not(*like_prefix_condition(prefix)) }
        collect_features_data(scope) do |feature_name|
          prefixes.none? { |prefix| feature_name.start_with?(prefix) }
        end
      rescue StandardError => e
        raise AdapterError, "Failed to load unprefixed features from ActiveRecord: #{e.message}"
      end

      def set_all_data(feature_name, data_hash)
        feature_name_str = feature_name.to_s
        retries = 5
        begin
          @model_class.transaction do
            record = @model_class.lock.find_or_create_by!(feature_name: feature_name_str)
            existing_data = record.data || {}
            existing_data = {} unless existing_data.is_a?(Hash)
            data_hash.each do |key, value|
              existing_data[key.to_s] = serialize_value(value)
            end
            record.update!(data: existing_data, updated_at: defined?(Time.current) ? Time.current : Time.now)
          end
        rescue ::ActiveRecord::StatementInvalid, ::ActiveRecord::ConnectionTimeoutError => e
          if (e.message.include?('database is locked') || e.message.include?('busy') || e.message.include?('timeout')) && retries > 0
            retries -= 1
            sleep(0.01 * (6 - retries))
            retry
          end
          raise AdapterError, "Failed to set all data in ActiveRecord: #{e.message}"
        rescue StandardError => e
          raise AdapterError, "Failed to set all data in ActiveRecord: #{e.message}"
        end
      end

      def delete_key(feature_name, key)
        with_retries('delete key') do
          @model_class.transaction do
            record = @model_class.lock.find_by(feature_name: feature_name.to_s)
            data = record&.data || {}
            next false unless data.is_a?(Hash) && data.key?(key.to_s)

            record.update!(data: data.except(key.to_s), updated_at: current_time)
            true
          end
        end
      end

      # Server-side allocation. The read, the bump and the write happen inside
      # one transaction holding the row lock, so two processes sharing the
      # database are serialized and can never be handed the same number. The
      # counter lives in the same row as the archive it numbers, which is why it
      # can never fall behind snapshots that survived a Redis flush.
      def next_sequence(feature_name, key, floor: 0)
        with_retries('allocate sequence') do
          @model_class.transaction do
            record = @model_class.lock.find_or_create_by!(feature_name: feature_name.to_s)
            data = record.data || {}
            data = {} unless data.is_a?(Hash)
            value = [data[key.to_s].to_i, floor.to_i].max + 1
            record.update!(data: data.merge(key.to_s => value), updated_at: current_time)
            value
          end
        end
      end

      private

      # `!` as the LIKE escape character rather than the customary backslash:
      # a literal backslash inside a SQL string is itself an escape in MySQL,
      # so `ESCAPE '\\'` is not portable across the three databases this
      # adapter supports.
      LIKE_ESCAPE = '!'

      def like_prefix_condition(prefix)
        pattern = prefix.gsub(/[!%_]/) { |char| "#{LIKE_ESCAPE}#{char}" }
        ["feature_name LIKE ? ESCAPE '#{LIKE_ESCAPE}'", "#{pattern}%"]
      end

      def collect_features_data(scope)
        result = {}
        scope.find_each do |record|
          feature_name = record.feature_name.to_s
          next if block_given? && !yield(feature_name)

          data = record.data || {}
          next unless data.is_a?(Hash)

          feature_data = {}
          data.each do |k, v|
            feature_data[k.to_s] = deserialize_value(v)
          end
          result[record.feature_name] = feature_data
        end
        result
      end

      def current_time
        defined?(Time.current) ? Time.current : Time.now
      end

      # SQLite reports concurrent writers as busy/locked rather than blocking;
      # retry with linear backoff before surfacing the failure.
      def with_retries(operation)
        retries = 5
        begin
          yield
        rescue ::ActiveRecord::StatementInvalid, ::ActiveRecord::ConnectionTimeoutError => e
          if (e.message.include?('database is locked') || e.message.include?('busy') ||
              e.message.include?('timeout')) && retries.positive?
            retries -= 1
            sleep(0.01 * (6 - retries))
            retry
          end
          raise AdapterError, "Failed to #{operation} in ActiveRecord: #{e.message}"
        rescue StandardError => e
          raise AdapterError, "Failed to #{operation} in ActiveRecord: #{e.message}"
        end
      end

      def default_model_class
        return MagickFeature if defined?(MagickFeature)

        # Create model class if it doesn't exist
        create_model_class
      end

      def create_model_class
        # Define the model class dynamically
        # Use ::ActiveRecord::VERSION to access from global namespace
        ar_major = ::ActiveRecord::VERSION::MAJOR
        ar_minor = ::ActiveRecord::VERSION::MINOR
        use_json = ar_major >= 8 || (ar_major == 7 && ar_minor >= 1)

        Object.const_set('MagickFeature', Class.new(::ActiveRecord::Base) do
          self.table_name = 'magick_features'

          # ActiveRecord 8.1 changed serialize signature - it now only accepts one argument
          # Use attribute :data, :json for ActiveRecord 7.1+ (including 8.1)
          # Fall back to serialize for older versions
          if use_json
            # ActiveRecord 7.1+ and 8.x use attribute with type
            attribute :data, :json, default: {}
          else
            # Older ActiveRecord versions use serialize
            serialize :data, Hash
          end

          def self.table_exists?
            connection.table_exists?(table_name)
          end
        end)
      end

      def serialize_value(value)
        case value
        when Hash, Array
          value
        when true
          @use_json ? true : 'true'
        when false
          @use_json ? false : 'false'
        else
          value
        end
      end

      def deserialize_value(value)
        return nil if value.nil?

        # For ActiveRecord 8.1+ with attribute :json, booleans are already booleans
        # For older versions with serialize, we convert from strings
        case value
        when Hash, Array
          # Same shape every adapter returns: Memory and Redis physically
          # round-trip through JSON, so nested keys come back as strings.
          # ActiveRecord can hand back the very Ruby object that was written
          # (the :json attribute keeps it until the record is re-read), so it
          # normalizes deliberately — otherwise the first read after boot
          # yields symbols, every cached read after it yields strings, and the
          # same flag evaluates differently depending on the serving layer.
          # Callers that want symbols normalize once at their own boundary
          # (see Feature#normalize_targeting).
          deep_stringify(value)
        when 'true'
          # String 'true' from older serialize - convert to boolean
          true
        when 'false'
          # String 'false' from older serialize - convert to boolean
          false
        when true, false
          # Already a boolean (from JSON attribute)
          value
        else
          value
        end
      end

      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), result| result[k.to_s] = deep_stringify(v) }
        when Array
          value.map { |v| deep_stringify(v) }
        when Symbol
          value.to_s
        else
          value
        end
      end
    end
  end
end
