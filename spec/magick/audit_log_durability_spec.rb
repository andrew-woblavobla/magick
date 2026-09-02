# frozen_string_literal: true

require 'spec_helper'

# Try to load ActiveRecord if available
begin
  require 'active_record'
rescue LoadError
  # ActiveRecord not available, will skip specs below
end

# The durable default: audit entries are written to every adapter that
# outlives the process, so history survives a restart and one process can read
# what another wrote. Only runs when the AR + SQLite dev dependencies are present.
if defined?(::ActiveRecord::Base)
  require_relative '../../lib/magick/adapters/active_record'

  RSpec.describe Magick::AuditLog, 'durability' do
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

    # Each "container" gets its own memory cache over the shared database,
    # the way separate processes do.
    def build_registry
      Magick::Adapters::Registry.new(
        Magick::Adapters::Memory.new,
        nil,
        active_record_adapter: Magick::Adapters::ActiveRecord.new(model_class: MagickFeature)
      )
    end

    let(:registry) { build_registry }
    let(:audit) { described_class.new(nil, adapter_registry: registry) }

    it 'reports itself durable when an adapter outlives the process' do
      expect(audit.durable?).to be true
    end

    it 'survives a process restart' do
      audit.log(:checkout, :enable, user_id: 'admin-1', changes: { value: true })

      restarted = described_class.new(nil, adapter_registry: build_registry)

      entry = restarted.entries(feature_name: :checkout).last
      expect(restarted.size).to eq(0) # nothing in the fresh process's ring
      expect(entry.action).to eq('enable')
      expect(entry.user_id).to eq('admin-1')
      expect(entry.changes).to eq({ value: true })
    end

    it 'makes entries written by one process readable by another' do
      container_a = described_class.new(nil, adapter_registry: build_registry)
      container_b = described_class.new(nil, adapter_registry: build_registry)

      container_a.log(:checkout, :enable, user_id: 'admin-a')
      container_b.log(:checkout, :disable, user_id: 'admin-b')

      expect(container_b.entries(feature_name: :checkout).map(&:action)).to eq(%w[enable disable])
      expect(container_a.entries(feature_name: :checkout).map(&:user_id)).to eq(%w[admin-a admin-b])
    end

    it 'lists entries across features when no feature_name is given' do
      other = described_class.new(nil, adapter_registry: build_registry)
      other.log(:checkout, :enable)
      other.log(:search, :disable)

      reader = described_class.new(nil, adapter_registry: build_registry)
      expect(reader.entries.map(&:feature_name)).to eq(%w[checkout search])
    end

    it 'keeps at most `retention` entries per feature' do
      capped = described_class.new(nil, adapter_registry: registry, retention: 3)
      5.times { |i| capped.log(:checkout, :set_value, changes: { value: i }) }

      reader = described_class.new(nil, adapter_registry: build_registry, retention: 3)
      expect(reader.entries(feature_name: :checkout).map { |e| e.changes[:value] }).to eq([2, 3, 4])
    end

    it 'keeps the history of a feature that was deleted' do
      Magick.adapter_registry = registry
      Magick.audit_log = audit
      Magick.register_feature(:doomed)
      Magick[:doomed].enable
      Magick[:doomed].delete

      restarted = described_class.new(nil, adapter_registry: build_registry)
      expect(restarted.entries(feature_name: :doomed).map(&:action)).to eq(%w[enable delete])
    end

    it 'keeps audit history out of the feature list' do
      audit.log(:checkout, :enable)
      expect(registry.all_features).not_to include(a_string_starting_with(described_class::STORE_PREFIX))
      expect(registry.preload!.keys).not_to include(a_string_starting_with(described_class::STORE_PREFIX))
    end

    it 'writes nothing durable when persistence is opted out' do
      opted_out = described_class.new(nil, adapter_registry: registry, persist: false)
      opted_out.log(:checkout, :enable)

      expect(opted_out.durable?).to be false
      expect(MagickFeature.where(feature_name: "#{described_class::STORE_PREFIX}checkout")).to be_empty
      expect(opted_out.entries(feature_name: :checkout).map(&:action)).to eq(['enable'])
    end

    describe 'through the configuration DSL' do
      it 'persists a default deployment across a restart' do
        Magick.configure do
          active_record model_class: MagickFeature
          audit_log enabled: true
        end
        Magick.register_feature(:checkout)
        Magick.with_actor('admin-9') { Magick[:checkout].enable }

        Magick.reset! # process restart
        Magick.configure do
          active_record model_class: MagickFeature
          audit_log enabled: true
        end

        entries = Magick.audit_log.entries(feature_name: :checkout)
        expect(entries.map(&:action)).to eq(['enable'])
        expect(entries.last.user_id).to eq('admin-9')
      end

      it 'records nothing at all when audit logging is disabled' do
        Magick.configure do
          active_record model_class: MagickFeature
          audit_log enabled: false
        end
        Magick.register_feature(:checkout)
        Magick[:checkout].enable

        expect(Magick.audit_log).to be_nil
        expect(MagickFeature.where(feature_name: "#{described_class::STORE_PREFIX}checkout")).to be_empty
      end
    end

    it 'still feeds a host-supplied adapter alongside the durable store' do
      sink = Class.new do
        attr_reader :appended

        def initialize
          @appended = []
        end

        def append(entry)
          @appended << entry
        end
      end.new

      with_sink = described_class.new(sink, adapter_registry: registry)
      with_sink.log(:checkout, :enable)

      restarted = described_class.new(nil, adapter_registry: build_registry)
      expect(sink.appended.map(&:action)).to eq(['enable'])
      expect(restarted.entries(feature_name: :checkout).map(&:action)).to eq(['enable'])
    end
  end
end
