# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

# Try to load ActiveRecord if available
begin
  require 'active_record'
rescue LoadError
  # ActiveRecord not available, will skip specs below
end

# Skip entire spec if ActiveRecord is not available
if defined?(::ActiveRecord::Base)
  require_relative '../../../lib/magick/adapters/active_record'

  RSpec.describe Magick::Adapters::ActiveRecord do
    # Set up in-memory SQLite database for testing
    before(:all) do
      # Try to load sqlite3 adapter
      begin
        require 'sqlite3'
      rescue LoadError
        skip 'SQLite3 gem not available. Install with: gem install sqlite3'
      end

      ActiveRecord::Base.establish_connection(
        adapter: 'sqlite3',
        database: ':memory:',
        pool: 20, # Increase pool size for concurrent tests
        timeout: 10_000 # Increase timeout for concurrent operations
        # Enable WAL mode for better concurrent read performance
        # Note: WAL mode doesn't work with :memory: database, but helps with file-based SQLite
        # For :memory:, we rely on retry logic
      )
      # Verify ActiveRecord version compatibility
      ar_version = "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
      puts "Testing with ActiveRecord #{ar_version}" if ENV['DEBUG']
    end

    after(:all) do
      ActiveRecord::Base.connection.close if ActiveRecord::Base.connected?
    end

    before(:each) do
      # Ensure table exists before each test by creating adapter
      described_class.new
      # Clean up before each test
      MagickFeature.delete_all if defined?(MagickFeature) && MagickFeature.table_exists?
    end

    let(:adapter) { described_class.new }

    describe 'initialization' do
      it 'creates table if it does not exist' do
        expect(adapter).to be_a(described_class)
        expect(MagickFeature.table_exists?).to be true
      end

      it 'accepts custom model class' do
        ar_major = ::ActiveRecord::VERSION::MAJOR
        ar_minor = ::ActiveRecord::VERSION::MINOR
        use_json = ar_major >= 8 || (ar_major == 7 && ar_minor >= 1)

        custom_model = Class.new(ActiveRecord::Base) do
          self.table_name = 'magick_features'
          # Use attribute :json for ActiveRecord 7.1+ and 8.x, serialize for older versions
          if use_json
            attribute :data, :json, default: {}
          else
            serialize :data, Hash
          end
        end

        custom_adapter = described_class.new(model_class: custom_model)
        expect(custom_adapter).to be_a(described_class)
      end

      it 'works with ActiveRecord 8.1' do
        # Verify ActiveRecord version compatibility (supports 6.x, 7.x, and 8.x)
        expect(::ActiveRecord::VERSION::MAJOR).to be >= 6

        # Test basic functionality
        adapter.set(:test_feature, 'value', true)
        expect(adapter.get(:test_feature, 'value')).to be true
      end

      it 'raises error if ActiveRecord connection fails' do
        allow(ActiveRecord::Base).to receive(:connection).and_raise(StandardError.new('Connection failed'))
        expect { described_class.new }.to raise_error(Magick::AdapterError)
      end
    end

    describe '#get and #set' do
      it 'stores and retrieves boolean values' do
        adapter.set(:test_feature, 'value', true)
        expect(adapter.get(:test_feature, 'value')).to be true

        adapter.set(:test_feature, 'value', false)
        expect(adapter.get(:test_feature, 'value')).to be false
      end

      it 'stores and retrieves string values' do
        adapter.set(:test_feature, 'value', 'test_string')
        expect(adapter.get(:test_feature, 'value')).to eq('test_string')
      end

      it 'stores and retrieves number values' do
        adapter.set(:test_feature, 'value', 42)
        expect(adapter.get(:test_feature, 'value')).to eq(42)

        adapter.set(:test_feature, 'value', 3.14)
        expect(adapter.get(:test_feature, 'value')).to eq(3.14)
      end

      it 'stores and retrieves hash values' do
        hash_value = { key1: 'value1', key2: 123 }
        adapter.set(:test_feature, 'targeting', hash_value)
        retrieved = adapter.get(:test_feature, 'targeting')
        expect(retrieved).to eq(hash_value)
      end

      it 'stores and retrieves array values' do
        array_value = [1, 2, 3, 'test']
        adapter.set(:test_feature, 'dependencies', array_value)
        retrieved = adapter.get(:test_feature, 'dependencies')
        expect(retrieved).to eq(array_value)
      end

      it 'handles multiple keys per feature' do
        adapter.set(:test_feature, 'value', true)
        adapter.set(:test_feature, 'status', 'active')
        adapter.set(:test_feature, 'description', 'Test feature')

        expect(adapter.get(:test_feature, 'value')).to be true
        expect(adapter.get(:test_feature, 'status')).to eq('active')
        expect(adapter.get(:test_feature, 'description')).to eq('Test feature')
      end

      it 'returns nil for non-existent keys' do
        expect(adapter.get(:non_existent, 'value')).to be_nil
      end

      it 'returns nil for non-existent features' do
        adapter.set(:test_feature, 'value', true)
        expect(adapter.get(:test_feature, 'non_existent_key')).to be_nil
      end

      it 'persists values across adapter instances' do
        adapter1 = described_class.new
        adapter1.set(:test_feature, 'value', true)

        adapter2 = described_class.new
        expect(adapter2.get(:test_feature, 'value')).to be true
      end

      it 'updates existing values' do
        adapter.set(:test_feature, 'value', false)
        adapter.set(:test_feature, 'value', true)
        expect(adapter.get(:test_feature, 'value')).to be true
      end

      it 'handles nil values' do
        adapter.set(:test_feature, 'value', nil)
        expect(adapter.get(:test_feature, 'value')).to be_nil
      end

      it 'handles empty string values' do
        adapter.set(:test_feature, 'value', '')
        expect(adapter.get(:test_feature, 'value')).to eq('')
      end

      it 'handles zero values' do
        adapter.set(:test_feature, 'value', 0)
        expect(adapter.get(:test_feature, 'value')).to eq(0)
      end

      it 'handles symbol keys' do
        adapter.set(:test_feature, :value, true)
        expect(adapter.get(:test_feature, :value)).to be true
        expect(adapter.get(:test_feature, 'value')).to be true
      end

      it 'handles symbol feature names' do
        adapter.set(:test_feature, 'value', true)
        expect(adapter.get('test_feature', 'value')).to be true
      end
    end

    describe '#delete' do
      it 'deletes a feature from database' do
        adapter.set(:test_feature, 'value', true)
        adapter.set(:test_feature, 'status', 'active')
        adapter.delete(:test_feature)
        expect(adapter.exists?(:test_feature)).to be false
        expect(adapter.get(:test_feature, 'value')).to be_nil
      end

      it 'deletes all keys for a feature' do
        adapter.set(:test_feature, 'value', true)
        adapter.set(:test_feature, 'status', 'active')
        adapter.set(:test_feature, 'description', 'Test')
        adapter.delete(:test_feature)

        expect(adapter.get(:test_feature, 'value')).to be_nil
        expect(adapter.get(:test_feature, 'status')).to be_nil
        expect(adapter.get(:test_feature, 'description')).to be_nil
      end

      it 'does not affect other features' do
        adapter.set(:feature1, 'value', true)
        adapter.set(:feature2, 'value', false)
        adapter.delete(:feature1)

        expect(adapter.exists?(:feature1)).to be false
        expect(adapter.exists?(:feature2)).to be true
        expect(adapter.get(:feature2, 'value')).to be false
      end

      it 'handles deleting non-existent features gracefully' do
        expect { adapter.delete(:non_existent) }.not_to raise_error
      end
    end

    describe '#exists?' do
      it 'returns true for existing features' do
        adapter.set(:test_feature, 'value', true)
        expect(adapter.exists?(:test_feature)).to be true
      end

      it 'returns false for non-existent features' do
        expect(adapter.exists?(:non_existent)).to be false
      end

      it 'handles symbol and string feature names' do
        adapter.set(:test_feature, 'value', true)
        expect(adapter.exists?('test_feature')).to be true
        expect(adapter.exists?(:test_feature)).to be true
      end
    end

    describe '#all_features' do
      it 'returns all feature names from database' do
        adapter.set(:feature1, 'value', true)
        adapter.set(:feature2, 'value', false)
        adapter.set(:feature3, 'value', 'test')

        features = adapter.all_features
        expect(features).to include('feature1', 'feature2', 'feature3')
      end

      it 'returns unique feature names' do
        adapter.set(:test_feature, 'value', true)
        adapter.set(:test_feature, 'status', 'active')
        adapter.set(:test_feature, 'description', 'Test')

        features = adapter.all_features
        expect(features.count('test_feature')).to eq(1)
      end

      it 'returns empty array when no features exist' do
        expect(adapter.all_features).to eq([])
      end

      it 'handles features with multiple keys' do
        adapter.set(:feature1, 'value', true)
        adapter.set(:feature1, 'status', 'active')
        adapter.set(:feature2, 'value', false)

        features = adapter.all_features
        expect(features.length).to eq(2)
        expect(features).to include('feature1', 'feature2')
      end
    end

    describe 'serialization and deserialization' do
      it 'correctly serializes boolean values' do
        adapter.set(:test_feature, 'value', true)
        record = MagickFeature.find_by(feature_name: 'test_feature')
        # ActiveRecord 8.1+ uses JSON which stores booleans as booleans, not strings
        # Older versions using serialize store as strings
        ar_major = ::ActiveRecord::VERSION::MAJOR
        ar_minor = ::ActiveRecord::VERSION::MINOR
        use_json = ar_major >= 8 || (ar_major == 7 && ar_minor >= 1)

        if use_json
          expect(record.data['value']).to eq(true)
        else
          expect(record.data['value']).to eq('true')
        end

        adapter.set(:test_feature, 'value', false)
        record.reload
        if use_json
          expect(record.data['value']).to eq(false)
        else
          expect(record.data['value']).to eq('false')
        end
      end

      it 'correctly deserializes boolean strings' do
        adapter.set(:test_feature, 'value', true)
        expect(adapter.get(:test_feature, 'value')).to be true

        adapter.set(:test_feature, 'value', false)
        expect(adapter.get(:test_feature, 'value')).to be false
      end

      it 'preserves complex nested structures' do
        complex_value = {
          targeting: {
            user: [1, 2, 3],
            group: %w[admin beta],
            percentage_users: 50.5
          },
          metadata: {
            created_at: '2024-01-01',
            tags: %w[feature test]
          }
        }
        adapter.set(:test_feature, 'config', complex_value)
        retrieved = adapter.get(:test_feature, 'config')
        expect(retrieved).to eq(complex_value)
      end

      it 'handles arrays with mixed types' do
        mixed_array = [1, 'string', true, false, { key: 'value' }, [1, 2, 3]]
        adapter.set(:test_feature, 'mixed', mixed_array)
        retrieved = adapter.get(:test_feature, 'mixed')
        expect(retrieved).to eq(mixed_array)
      end
    end

    describe 'as fallback adapter' do
      it 'is used when memory adapter value is missing' do
        memory_adapter = Magick::Adapters::Memory.new
        active_record_adapter = described_class.new
        registry = Magick::Adapters::Registry.new(memory_adapter, nil, active_record_adapter: active_record_adapter)

        # Set value in Active Record adapter
        active_record_adapter.set(:test_feature, 'value', true)

        # Should retrieve from Active Record when memory is empty
        expect(registry.get(:test_feature, 'value')).to be true
        # Should also update memory cache
        expect(memory_adapter.get(:test_feature, 'value')).to be true
      end

      it 'is used when Redis adapter fails' do
        memory_adapter = Magick::Adapters::Memory.new
        redis_adapter = double('RedisAdapter', get: nil)
        active_record_adapter = described_class.new
        registry = Magick::Adapters::Registry.new(memory_adapter, redis_adapter,
                                                  active_record_adapter: active_record_adapter)

        # Set value in Active Record adapter
        active_record_adapter.set(:test_feature, 'value', true)

        # Should retrieve from Active Record when Redis fails
        allow(redis_adapter).to receive(:get).and_raise(StandardError)
        expect(registry.get(:test_feature, 'value')).to be true
      end

      it 'is used when Redis adapter returns nil' do
        memory_adapter = Magick::Adapters::Memory.new
        redis_adapter = double('RedisAdapter')
        active_record_adapter = described_class.new
        registry = Magick::Adapters::Registry.new(memory_adapter, redis_adapter,
                                                  active_record_adapter: active_record_adapter)

        active_record_adapter.set(:test_feature, 'value', true)
        allow(redis_adapter).to receive(:get).and_return(nil)

        expect(registry.get(:test_feature, 'value')).to be true
      end

      it 'updates memory cache when retrieving from Active Record' do
        memory_adapter = Magick::Adapters::Memory.new
        active_record_adapter = described_class.new
        registry = Magick::Adapters::Registry.new(memory_adapter, nil, active_record_adapter: active_record_adapter)

        active_record_adapter.set(:test_feature, 'value', true)
        registry.get(:test_feature, 'value')

        # Memory cache should be updated
        expect(memory_adapter.get(:test_feature, 'value')).to be true
      end
    end

    describe 'as primary adapter' do
      it 'can be configured as the primary adapter' do
        active_record_adapter = described_class.new
        registry = Magick::Adapters::Registry.new(nil, nil, active_record_adapter: active_record_adapter,
                                                            primary: :active_record)

        registry.set(:test_feature, 'value', true)
        expect(registry.get(:test_feature, 'value')).to be true
      end

      it 'writes directly to Active Record when primary' do
        active_record_adapter = described_class.new
        registry = Magick::Adapters::Registry.new(nil, nil, active_record_adapter: active_record_adapter,
                                                            primary: :active_record)

        registry.set(:test_feature, 'value', true)
        expect(active_record_adapter.get(:test_feature, 'value')).to be true
      end
    end

    describe 'thread safety' do
      # Use a file-based SQLite database for thread safety tests
      # because :memory: databases are connection-specific and threads use different connections
      before(:all) do
        @thread_test_db = Tempfile.new(['magick_test', '.db'])
        @thread_test_db.close
        ActiveRecord::Base.establish_connection(
          adapter: 'sqlite3',
          database: @thread_test_db.path,
          pool: 20,
          timeout: 10_000
        )
      end

      after(:all) do
        if @thread_test_db
          ActiveRecord::Base.connection.close if ActiveRecord::Base.connected?
          File.unlink(@thread_test_db.path) if File.exist?(@thread_test_db.path)
        end
        # Restore original in-memory connection
        ActiveRecord::Base.establish_connection(
          adapter: 'sqlite3',
          database: ':memory:',
          pool: 20,
          timeout: 10_000
        )
      end

      before(:each) do
        # Ensure table exists before thread safety tests
        # Create adapter instance to trigger table creation
        adapter_instance = described_class.new
        # Force table creation if it doesn't exist
        adapter_instance.send(:ensure_table_exists) unless MagickFeature.table_exists?
        # Wait a bit to ensure table creation is complete across all connections
        sleep 0.1
        # Verify table exists
        raise "Table magick_features should exist but doesn't" unless MagickFeature.table_exists?

        # Clean up any existing data
        MagickFeature.delete_all if defined?(MagickFeature) && MagickFeature.table_exists?
      end

      # Ensure adapter instance also has table ready
      # Use a shared adapter instance for all threads (ActiveRecord handles connection pooling)
      let(:adapter) do
        @adapter_instance ||= begin
          instance = described_class.new
          instance.send(:ensure_table_exists) unless MagickFeature.table_exists?
          instance
        end
      end

      it 'handles concurrent writes' do
        threads = []
        errors = []
        10.times do |i|
          threads << Thread.new do
            adapter.set("feature_#{i}", 'value', i)
          rescue StandardError => e
            errors << e
          end
        end
        threads.each(&:join)

        # Check for errors first
        raise "Thread errors occurred: #{errors.map(&:message).join(', ')}" if errors.any?

        # Force connection to be established and wait a bit for all writes to complete
        ActiveRecord::Base.connection.reconnect!
        sleep 0.1

        expect(adapter.all_features.length).to eq(10)
        10.times do |i|
          expect(adapter.get("feature_#{i}", 'value')).to eq(i)
        end
      end

      it 'handles concurrent reads and writes' do
        adapter.set(:test_feature, 'value', 0)

        threads = []
        errors = []
        5.times do
          threads << Thread.new do
            # Read and write concurrently
            current = adapter.get(:test_feature, 'value') || 0
            adapter.set(:test_feature, 'value', current + 1)
          rescue StandardError => e
            errors << e
          end
        end
        threads.each(&:join)

        # Check for errors first
        raise "Thread errors occurred: #{errors.map(&:message).join(', ')}" if errors.any?

        # Wait a bit for all writes to be committed
        sleep 0.1

        # Final value should be at least 5 (may be more due to race conditions)
        final_value = adapter.get(:test_feature, 'value')
        expect(final_value).to be >= 5
      end

      it 'handles concurrent deletes' do
        # Set up features
        10.times { |i| adapter.set("feature_#{i}", 'value', i) }

        threads = []
        errors = []
        10.times do |i|
          threads << Thread.new do
            adapter.delete("feature_#{i}")
          rescue StandardError => e
            errors << e
          end
        end
        threads.each(&:join)

        # Check for errors first
        raise "Thread errors occurred: #{errors.map(&:message).join(', ')}" if errors.any?

        # Wait a bit for all deletes to be committed
        sleep 0.1

        expect(adapter.all_features.length).to eq(0)
      end
    end

    describe 'error handling' do
      it 'raises AdapterError on get failure' do
        # Ensure MagickFeature is created first
        adapter.set(:test_feature, 'value', true)
        allow(MagickFeature).to receive(:find_by).and_raise(StandardError.new('DB error'))
        expect do
          adapter.get(:test_feature, 'value')
        end.to raise_error(Magick::AdapterError, /Failed to get from ActiveRecord/)
      end

      it 'raises AdapterError on set failure' do
        # Ensure MagickFeature is created first by using the adapter
        adapter.set(:test_feature, 'value', false) # This creates MagickFeature
        allow_any_instance_of(MagickFeature).to receive(:save!).and_raise(StandardError.new('DB error'))
        expect do
          adapter.set(:test_feature, 'value', true)
        end.to raise_error(Magick::AdapterError, /Failed to set in ActiveRecord/)
      end

      it 'raises AdapterError on delete failure' do
        # Ensure MagickFeature is created first
        adapter.set(:test_feature, 'value', true)
        allow(MagickFeature).to receive(:where).and_raise(StandardError.new('DB error'))
        expect do
          adapter.delete(:test_feature)
        end.to raise_error(Magick::AdapterError, /Failed to delete from ActiveRecord/)
      end

      it 'raises AdapterError on exists? failure' do
        # Ensure MagickFeature is created first by using the adapter
        adapter.set(:test_feature, 'value', true) # This creates MagickFeature
        allow(MagickFeature).to receive(:exists?).and_raise(StandardError.new('DB error'))
        expect do
          adapter.exists?(:test_feature)
        end.to raise_error(Magick::AdapterError, /Failed to check existence in ActiveRecord/)
      end

      it 'raises AdapterError on all_features failure' do
        # Ensure MagickFeature is created first by using the adapter
        adapter.set(:test_feature, 'value', true) # This creates MagickFeature
        allow(MagickFeature).to receive(:pluck).and_raise(StandardError.new('DB error'))
        expect do
          adapter.all_features
        end.to raise_error(Magick::AdapterError, /Failed to get all features from ActiveRecord/)
      end
    end

    describe 'integration with Feature class' do
      it 'works with Feature#enabled?' do
        # Ensure MagickFeature is created first by using the adapter
        adapter.set(:test_feature, 'value', false)

        Magick.configure do
          active_record model_class: MagickFeature
        end

        feature = Magick::Feature.new(:test_feature, Magick.adapter_registry, type: :boolean, default_value: false)
        feature.enable
        expect(feature.enabled?).to be true

        # Reload feature and verify persistence
        feature2 = Magick::Feature.new(:test_feature, Magick.adapter_registry, type: :boolean, default_value: false)
        expect(feature2.enabled?).to be true
      end

      it 'works with Feature#get_value' do
        # Ensure MagickFeature is created first by using the adapter
        adapter.set(:test_feature, 'value', 'default')

        Magick.configure do
          active_record model_class: MagickFeature
        end

        feature = Magick::Feature.new(:test_feature, Magick.adapter_registry, type: :string, default_value: 'default')
        feature.set_value('custom_value')
        expect(feature.get_value).to eq('custom_value')

        # Reload feature and verify persistence
        feature2 = Magick::Feature.new(:test_feature, Magick.adapter_registry, type: :string, default_value: 'default')
        expect(feature2.get_value).to eq('custom_value')
      end

      it 'persists targeting rules' do
        # Ensure MagickFeature is created first by using the adapter
        adapter.set(:test_feature, 'targeting', {})

        Magick.configure do
          active_record model_class: MagickFeature
        end

        feature = Magick::Feature.new(:test_feature, Magick.adapter_registry, type: :boolean, default_value: false)
        feature.enable_for_user(123)
        feature.enable_for_group('beta')

        # Reload feature and verify targeting
        feature2 = Magick::Feature.new(:test_feature, Magick.adapter_registry, type: :boolean, default_value: false)
        expect(feature2.enabled?(user_id: 123)).to be true
        expect(feature2.enabled?(group: 'beta')).to be true
      end
    end

    describe 'edge cases' do
      it 'handles very long feature names' do
        long_name = 'a' * 255
        adapter.set(long_name, 'value', true)
        expect(adapter.get(long_name, 'value')).to be true
      end

      it 'handles special characters in feature names' do
        special_name = 'test-feature_123.test'
        adapter.set(special_name, 'value', true)
        expect(adapter.get(special_name, 'value')).to be true
      end

      it 'handles unicode characters' do
        adapter.set(:test_feature, 'description', 'Тест 测试 テスト')
        expect(adapter.get(:test_feature, 'description')).to eq('Тест 测试 テスト')
      end

      it 'handles very large hash values' do
        large_hash = {}
        1000.times { |i| large_hash["key_#{i}"] = "value_#{i}" }
        adapter.set(:test_feature, 'large_data', large_hash)
        retrieved = adapter.get(:test_feature, 'large_data')
        expect(retrieved.keys.length).to eq(1000)
      end

      it 'handles timestamp updates' do
        adapter.set(:test_feature, 'value', true)
        record1 = MagickFeature.find_by(feature_name: 'test_feature')
        first_updated_at = record1.updated_at

        sleep(0.1) # Ensure time difference
        adapter.set(:test_feature, 'value', false)
        record1.reload
        expect(record1.updated_at).to be > first_updated_at
      end
    end
  end
else
  RSpec.describe 'Magick::Adapters::ActiveRecord' do
    it 'requires ActiveRecord to be available' do
      skip 'Active Record adapter requires ActiveRecord. Install with: bundle install'
    end
  end
end
