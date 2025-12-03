# frozen_string_literal: true

module Magick
  module Adapters
    class ActiveRecord < Base
      @table_created_mutex = Mutex.new
      @table_created = false

      def initialize(model_class: nil)
        @model_class = model_class || default_model_class
        ensure_table_exists
      rescue StandardError => e
        raise AdapterError, "Failed to initialize ActiveRecord adapter: #{e.message}"
      end

      def get(feature_name, key)
        ensure_table_exists unless @model_class.table_exists?
        feature_name_str = feature_name.to_s
        record = @model_class.find_by(feature_name: feature_name_str)
        return nil unless record

        # Handle both Hash (from serialize) and Hash/JSON (from attribute :json)
        data = record.data || {}
        value = data.is_a?(Hash) ? data[key.to_s] : nil
        deserialize_value(value)
      rescue StandardError => e
        # If table doesn't exist, try to create it and retry once
        if e.message.include?('no such table') || e.message.include?("doesn't exist")
          ensure_table_exists
          retry
        end
        raise AdapterError, "Failed to get from ActiveRecord: #{e.message}"
      end

      def set(feature_name, key, value)
        ensure_table_exists unless @model_class.table_exists?
        feature_name_str = feature_name.to_s
        retries = 5
        begin
          record = @model_class.find_or_initialize_by(feature_name: feature_name_str)
          # Ensure data is a Hash (works for both serialize and attribute :json)
          data = record.data || {}
          data = {} unless data.is_a?(Hash)
          data[key.to_s] = serialize_value(value)
          record.data = data
          # Use Time.now if Time.current is not available (for non-Rails environments)
          record.updated_at = defined?(Time.current) ? Time.current : Time.now
          record.save!
        rescue ::ActiveRecord::StatementInvalid, ::ActiveRecord::ConnectionTimeoutError => e
          # SQLite busy/locked errors - retry with exponential backoff
          if (e.message.include?('database is locked') || e.message.include?('busy') || e.message.include?('timeout') || e.message.include?('no such table')) && retries > 0
            retries -= 1
            # If it's a "no such table" error, ensure table exists
            if e.message.include?('no such table')
              ensure_table_exists
            end
            sleep(0.01 * (6 - retries)) # Exponential backoff: 0.01, 0.02, 0.03, 0.04, 0.05
            retry
          end
          raise AdapterError, "Failed to set in ActiveRecord: #{e.message}"
        rescue StandardError => e
          # If table doesn't exist, try to create it and retry once
          if (e.message.include?('no such table') || e.message.include?("doesn't exist")) && retries > 0
            retries -= 1
            ensure_table_exists
            sleep(0.01)
            retry
          end
          raise AdapterError, "Failed to set in ActiveRecord: #{e.message}"
        end
      end

      def delete(feature_name)
        ensure_table_exists unless @model_class.table_exists?
        feature_name_str = feature_name.to_s
        retries = 5
        begin
          @model_class.where(feature_name: feature_name_str).destroy_all
        rescue ::ActiveRecord::StatementInvalid, ::ActiveRecord::ConnectionTimeoutError => e
          # SQLite busy/locked errors - retry with exponential backoff
          if (e.message.include?('database is locked') || e.message.include?('busy') || e.message.include?('timeout') || e.message.include?('no such table')) && retries > 0
            retries -= 1
            # If it's a "no such table" error, ensure table exists
            if e.message.include?('no such table')
              ensure_table_exists
            end
            sleep(0.01 * (6 - retries)) # Exponential backoff: 0.01, 0.02, 0.03, 0.04, 0.05
            retry
          end
          raise AdapterError, "Failed to delete from ActiveRecord: #{e.message}"
        rescue StandardError => e
          # If table doesn't exist, try to create it and retry once
          if (e.message.include?('no such table') || e.message.include?("doesn't exist")) && retries > 0
            retries -= 1
            ensure_table_exists
            sleep(0.01)
            retry
          end
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

      private

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

      def ensure_table_exists
        return if @model_class.table_exists?

        # Use a non-blocking mutex to prevent deadlocks
        mutex = self.class.instance_variable_get(:@table_created_mutex)
        if mutex.try_lock
          begin
            # Double-check after acquiring lock
            return if @model_class.table_exists?

            create_table
            self.class.instance_variable_set(:@table_created, true)
          ensure
            mutex.unlock
          end
        else
          # Another thread is creating the table, wait for it to complete
          # Use a longer timeout with exponential backoff to avoid hanging
          20.times do |i|
            sleep(0.01 * (i + 1)) # Exponential backoff: 0.01, 0.02, 0.03, ...
            return if @model_class.table_exists?
          end
          # If we still don't have the table, try one more time
          unless @model_class.table_exists?
            # Last attempt: try to acquire lock and create
            if mutex.try_lock
              begin
                return if @model_class.table_exists?
                create_table
                self.class.instance_variable_set(:@table_created, true)
              ensure
                mutex.unlock
              end
            end
          end
        end
      rescue StandardError => e
        # Don't raise if table exists now (might have been created by another thread)
        return if @model_class.table_exists?
        raise e
      end

      def create_table
        connection = @model_class.connection
        return if connection.table_exists?('magick_features')

        connection.create_table :magick_features do |t|
          t.string :feature_name, null: false, index: { unique: true }
          t.text :data
          t.timestamps
        end
      rescue StandardError => e
        # Table might already exist or migration might be needed
        # Check if table exists now (might have been created by another thread)
        return if connection.table_exists?('magick_features')

        warn "Magick: Could not create magick_features table: #{e.message}" if defined?(Rails) && Rails.env.development?
        raise e if defined?(Rails) && Rails.env.test?
      end

      def serialize_value(value)
        # For ActiveRecord 8.1+ with attribute :json, we can store booleans as-is
        # For older versions with serialize, we convert to strings
        ar_major = ::ActiveRecord::VERSION::MAJOR
        ar_minor = ::ActiveRecord::VERSION::MINOR
        use_json = ar_major >= 8 || (ar_major == 7 && ar_minor >= 1)

        case value
        when Hash, Array
          value
        when true
          use_json ? true : 'true'
        when false
          use_json ? false : 'false'
        else
          value
        end
      end

      def deserialize_value(value)
        return nil if value.nil?

        # For ActiveRecord 8.1+ with attribute :json, booleans are already booleans
        # For older versions with serialize, we convert from strings
        case value
        when Hash
          # JSON serialization converts symbol keys to strings
          # Convert string keys back to symbols for consistency with input
          symbolize_hash_keys(value)
        when Array
          # Recursively process array elements
          value.map { |v| v.is_a?(Hash) ? symbolize_hash_keys(v) : v }
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

      def symbolize_hash_keys(hash)
        return hash unless hash.is_a?(Hash)

        hash.each_with_object({}) do |(k, v), result|
          key = k.is_a?(String) ? k.to_sym : k
          result[key] = v.is_a?(Hash) ? symbolize_hash_keys(v) : (v.is_a?(Array) ? v.map { |item| item.is_a?(Hash) ? symbolize_hash_keys(item) : item } : v)
        end
      end
    end
  end
end
