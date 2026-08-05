# frozen_string_literal: true

require 'spec_helper'

# Try to load ActiveRecord if available
begin
  require 'active_record'
rescue LoadError
  # ActiveRecord not available, will skip specs below
end

# Tiered retention: hot window in memory/Redis, unlimited archive in
# ActiveRecord. Only runs when the AR + SQLite dev dependencies are present.
if defined?(::ActiveRecord::Base)
  require_relative '../../lib/magick/adapters/active_record'

  RSpec.describe Magick::Versioning, 'ActiveRecord archive' do
    before(:all) do
      begin
        require 'sqlite3'
      rescue LoadError
        skip 'SQLite3 gem not available. Install with: gem install sqlite3'
      end

      ActiveRecord::Base.establish_connection(
        adapter: 'sqlite3',
        database: ':memory:',
        pool: 20,
        timeout: 10_000
      )
    end

    after(:all) do
      ActiveRecord::Base.connection.close if ActiveRecord::Base.connected?
    end

    before(:each) do
      unless ActiveRecord::Base.connection.table_exists?('magick_features')
        ActiveRecord::Base.connection.create_table :magick_features do |t|
          t.string :feature_name, null: false
          t.text :data
          t.timestamps
        end
        ActiveRecord::Base.connection.add_index :magick_features, :feature_name, unique: true
      end

      unless defined?(MagickFeature)
        ar_major = ::ActiveRecord::VERSION::MAJOR
        ar_minor = ::ActiveRecord::VERSION::MINOR
        use_json = ar_major >= 8 || (ar_major == 7 && ar_minor >= 1)

        Object.const_set('MagickFeature', Class.new(ActiveRecord::Base) do
          self.table_name = 'magick_features'
          if use_json
            attribute :data, :json, default: {}
          else
            serialize :data, Hash
          end
        end)
      end

      MagickFeature.delete_all if MagickFeature.table_exists?
    end

    let(:memory_adapter) { Magick::Adapters::Memory.new }
    let(:ar_adapter) { Magick::Adapters::ActiveRecord.new(model_class: MagickFeature) }
    let(:registry) do
      Magick::Adapters::Registry.new(memory_adapter, nil, active_record_adapter: ar_adapter)
    end
    let(:versioning) { described_class.new(registry, max_versions: 3) }

    before do
      Magick.adapter_registry = registry
      Magick.register_feature(:av_demo)
    end

    it 'keeps every version in the archive while the hot window prunes' do
      5.times { versioning.save_version(:av_demo) }

      expect(versioning.get_versions(:av_demo).map(&:version)).to eq([3, 4, 5])
      expect(versioning.get_versions(:av_demo, all: true).map(&:version)).to eq([1, 2, 3, 4, 5])
    end

    it 'rolls back to a version that has already left the hot window' do
      Magick.versioning = versioning
      Magick[:av_demo].set_value(true)  # version 1 — archived, later pruned from hot
      Magick[:av_demo].set_value(false) # 2
      Magick[:av_demo].set_value(true)  # 3
      Magick[:av_demo].set_value(false) # 4
      Magick[:av_demo].set_value(false) # 5

      expect(versioning.get_versions(:av_demo).map(&:version)).to eq([3, 4, 5])

      expect(versioning.rollback(:av_demo, 1)).to be true
      expect(Magick[:av_demo].enabled?).to be true
    end

    it 'retains the archive after the feature is deleted' do
      Magick.versioning = versioning
      Magick[:av_demo].set_value(true)
      Magick[:av_demo].delete

      history = versioning.get_versions(:av_demo, all: true)
      expect(history.map(&:action)).to eq(%w[set_value delete])
      expect(registry.exists?(:av_demo)).to be false
    end

    it 'continues numbering from the archive after memory is wiped (restart)' do
      Magick.versioning = versioning
      Magick[:av_demo].set_value(true)
      Magick[:av_demo].set_value(false)

      fresh_memory = Magick::Adapters::Memory.new
      fresh_registry = Magick::Adapters::Registry.new(fresh_memory, nil, active_record_adapter: ar_adapter)
      fresh = described_class.new(fresh_registry, max_versions: 3)

      expect(fresh.get_versions(:av_demo).map(&:version)).to eq([1, 2])
      expect(fresh.save_version(:av_demo).version).to eq(3)
    end
  end
end
