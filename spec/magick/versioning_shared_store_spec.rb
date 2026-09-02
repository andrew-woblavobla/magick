# frozen_string_literal: true

require 'spec_helper'

begin
  require 'active_record'
rescue LoadError
  # ActiveRecord not available, will skip specs below
end

# Two versioning instances over ONE shared backend — the multi-container setup
# that 1.5.0 got wrong: each process numbered versions from its own memoized
# window and wrote the whole list back, so containers overwrote each other's
# snapshots and disagreed about what a version number contained.
#
# Appends here are sequential on purpose. A SQLite :memory: database is private
# to the connection that opened it, so threads would each end up talking to
# their own database instead of a shared one; concurrent allocation is covered
# in versioning_spec.rb (shared memory store) and redis_integration_spec.rb.
if defined?(::ActiveRecord::Base)
  require_relative '../../lib/magick/adapters/active_record'

  RSpec.describe Magick::Versioning, 'shared backend' do
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

    # Each "container" gets its own memory cache and its own adapter object;
    # the database underneath them is the same.
    def container
      Magick::Adapters::Registry.new(
        Magick::Adapters::Memory.new,
        nil,
        active_record_adapter: Magick::Adapters::ActiveRecord.new(model_class: MagickFeature)
      )
    end

    let(:container_a) { container }
    let(:container_b) { container }
    let(:versioning_a) { described_class.new(container_a) }
    let(:versioning_b) { described_class.new(container_b) }
    let(:feature) { Magick.features['shared_demo'] }

    before do
      Magick.adapter_registry = container_a
      Magick.register_feature(:shared_demo)
    end

    def markers(versioning)
      versioning.get_versions(:shared_demo, all: true).map { |v| [v.version, v.feature_data[:marker]] }
    end

    it 'interleaves both containers into one history with no lost snapshots' do
      3.times do |i|
        versioning_a.record_change(feature, action: 'a', snapshot: { marker: "A#{i}" })
        versioning_b.record_change(feature, action: 'b', snapshot: { marker: "B#{i}" })
      end

      expect(markers(versioning_a)).to eq(
        [[1, 'A0'], [2, 'B0'], [3, 'A1'], [4, 'B1'], [5, 'A2'], [6, 'B2']]
      )
    end

    it 'never hands the same number to two containers' do
      numbers = 4.times.flat_map do |i|
        [
          versioning_a.record_change(feature, action: 'a', snapshot: { marker: "A#{i}" }).version,
          versioning_b.record_change(feature, action: 'b', snapshot: { marker: "B#{i}" }).version
        ]
      end

      expect(numbers).to eq((1..8).to_a)
    end

    it 'resolves every version number to the same snapshot in either container' do
      2.times do |i|
        versioning_a.record_change(feature, action: 'a', snapshot: { marker: "A#{i}" })
        versioning_b.record_change(feature, action: 'b', snapshot: { marker: "B#{i}" })
      end

      expect(markers(versioning_b)).to eq(markers(versioning_a))
      expect(versioning_b.get_versions(:shared_demo).map(&:version))
        .to eq(versioning_a.get_versions(:shared_demo).map(&:version))
    end

    it 'takes the next number from the store, not from a window read earlier in this process' do
      versioning_a.record_change(feature, action: 'a', snapshot: { marker: 'A0' })
      versioning_a.get_versions(:shared_demo) # this process has now read history once

      3.times { |i| versioning_b.record_change(feature, action: 'b', snapshot: { marker: "B#{i}" }) }

      entry = versioning_a.record_change(feature, action: 'a', snapshot: { marker: 'A1' })
      expect(entry.version).to eq(5)
      expect(markers(versioning_a).map(&:first)).to eq([1, 2, 3, 4, 5])
    end

    it 'rolls back to the same snapshot whichever container serves the request' do
      Magick.versioning = versioning_a
      Magick[:shared_demo].set_value(true)  # version 1, recorded by container A
      Magick.versioning = versioning_b
      Magick[:shared_demo].set_value(false) # version 2, recorded by container B
      Magick.versioning = versioning_a
      Magick[:shared_demo].set_value(true)  # version 3, recorded by container A

      from_a = versioning_a.get_versions(:shared_demo, all: true).find { |v| v.version == 2 }
      from_b = versioning_b.get_versions(:shared_demo, all: true).find { |v| v.version == 2 }
      expect(from_b.feature_data).to eq(from_a.feature_data)

      expect(versioning_b.rollback(:shared_demo, 2)).to be true
      expect(Magick[:shared_demo].enabled?).to be false
    end

    it 'archives one row per version instead of a list every append rewrites' do
      versioning_a.record_change(feature, action: 'a', snapshot: { marker: 'A0' })
      versioning_b.record_change(feature, action: 'b', snapshot: { marker: 'B0' })

      prefix = "#{described_class::STORE_PREFIX}shared_demo#{described_class::ARCHIVE_ROW_INFIX}"
      rows = MagickFeature.where("feature_name LIKE ?", "#{prefix}%").order(:feature_name)
      expect(rows.pluck(:feature_name)).to eq(["#{prefix}1", "#{prefix}2"])
      expect(rows.map { |row| row.data.keys }).to all(eq([described_class::ARCHIVE_DATA_KEY]))
    end
  end
end
