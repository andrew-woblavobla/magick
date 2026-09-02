# frozen_string_literal: true

require 'spec_helper'

begin
  require 'active_record'
rescue LoadError
  # ActiveRecord not available, will skip specs below
end

# Version history is bookkeeping, and it is unbounded. It must stay out of the
# paths that only ever want features — the boot-time cache preload and the
# Admin UI's per-render source refresh — and appending to it must cost one
# snapshot, not a rewrite of every snapshot before it.
if defined?(::ActiveRecord::Base)
  require_relative '../../lib/magick/adapters/active_record'

  RSpec.describe Magick::Versioning, 'hot path' do
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
    let(:versioning) { described_class.new(registry, max_versions: 5) }
    let(:reserved) { described_class::STORE_PREFIX }

    before do
      Magick.adapter_registry = registry
      Magick.versioning = versioning
      Magick.register_feature(:hp_demo)
      Magick[:hp_demo].set_value(true)
    end

    # The ticket's measurement: 120 toggles of a single flag, ~37 KB of
    # snapshots, all of it in the reserved namespace.
    def toggle(times)
      times.times { |i| Magick[:hp_demo].set_value(i.even?) }
    end

    def reserved_rows
      MagickFeature.where('feature_name LIKE ?', "#{reserved}%")
    end

    describe 'bulk preload' do
      it 'leaves the memory adapter with no version snapshots' do
        toggle(120)
        expect(reserved_rows.count).to be >= 120

        fresh_memory = Magick::Adapters::Memory.new
        fresh_registry = Magick::Adapters::Registry.new(fresh_memory, nil, active_record_adapter: ar_adapter)

        loaded = fresh_registry.preload!

        expect(loaded.keys).to include('hp_demo')
        expect(loaded.keys.grep(/\A#{Regexp.escape(reserved)}/)).to be_empty
        expect(fresh_memory.all_features).to eq(['hp_demo'])
        expect(fresh_memory.get_all_data('hp_demo')).to include('value')
      end

      it 'reads no version rows out of the database at all' do
        toggle(120)

        fresh_registry = Magick::Adapters::Registry.new(
          Magick::Adapters::Memory.new, nil, active_record_adapter: ar_adapter
        )

        rows_read = 0
        subscriber = ActiveSupport::Notifications.subscribe('instantiation.active_record') do |*args|
          payload = ActiveSupport::Notifications::Event.new(*args).payload
          rows_read += payload[:record_count].to_i if payload[:class_name] == 'MagickFeature'
        end
        begin
          fresh_registry.preload!
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        # One row: the feature itself. The archive is filtered in SQL, so its
        # rows never leave the database, rather than being discarded after the
        # fact — that read is the cost this ticket is about.
        expect(rows_read).to eq(1)
      end
    end

    describe 'the Admin UI source refresh' do
      it 'refreshes every feature without pulling the version archive into memory' do
        toggle(120)

        fresh_memory = Magick::Adapters::Memory.new
        fresh_registry = Magick::Adapters::Registry.new(fresh_memory, nil, active_record_adapter: ar_adapter)

        refreshed = fresh_registry.refresh_all_from_source

        expect(refreshed.keys).to eq(['hp_demo'])
        expect(fresh_memory.all_features).to eq(['hp_demo'])
      end
    end

    describe 'appending' do
      # Bytes actually sent to the database for writes: the statement plus its
      # bound values, which for this schema is the row's whole JSON blob.
      def bytes_written
        written = 0
        subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
          payload = ActiveSupport::Notifications::Event.new(*args).payload
          sql = payload[:sql].to_s
          next unless sql.match?(/\A\s*(INSERT|UPDATE)/i)

          written += sql.bytesize + Array(payload[:type_casted_binds]).sum { |value| value.to_s.bytesize }
        end
        begin
          yield
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end
        written
      end

      it 'writes one version worth of data however long the history already is' do
        toggle(5)
        early = bytes_written { versioning.save_version(:hp_demo) }

        toggle(100)
        late = bytes_written { versioning.save_version(:hp_demo) }

        archive_bytes = reserved_rows.sum { |row| JSON.generate(row.data).bytesize }

        # The archive is now big enough that a read-modify-write of the whole
        # history would be unmistakable, and appending still costs the same.
        expect(archive_bytes).to be > (late * 20)
        expect(late).to be < (early * 1.5)
      end

      it 'gives each version its own row, holding only that version' do
        toggle(3)

        rows = MagickFeature.where('feature_name LIKE ?', "#{reserved}hp_demo#{described_class::ARCHIVE_ROW_INFIX}%")
        expect(rows.count).to eq(versioning.get_versions(:hp_demo, all: true).size)
        expect(rows.map { |row| row.data.keys }).to all(eq([described_class::ARCHIVE_DATA_KEY]))
      end

      it 'keeps the version counter out of the rows that hold snapshots' do
        toggle(3)

        counter = MagickFeature.find_by(feature_name: "#{reserved}hp_demo#{described_class::SEQUENCE_ROW_SUFFIX}")
        expect(counter.data.keys).to eq([described_class::SEQUENCE_KEY])
      end
    end

    describe 'an archive written before the per-row layout' do
      # Releases up to 1.6.1 kept every snapshot as a version_<n> key inside the
      # feature's single archive row.
      let(:legacy_store) { "#{reserved}legacy_demo" }

      before do
        Magick.register_feature(:legacy_demo)
        (1..5).each do |number|
          ar_adapter.set(legacy_store, "version_#{number}", {
                           version: number,
                           feature_data: { name: 'legacy_demo', value: number.odd?, targeting: {} },
                           timestamp: Time.now.iso8601,
                           created_by: nil,
                           action: 'set_value'
                         })
        end
      end

      it 'still reads the whole history' do
        fresh = described_class.new(
          Magick::Adapters::Registry.new(Magick::Adapters::Memory.new, nil, active_record_adapter: ar_adapter),
          max_versions: 5
        )

        expect(fresh.get_versions(:legacy_demo, all: true).map(&:version)).to eq([1, 2, 3, 4, 5])
      end

      it 'still rolls back to a version stored in the old layout' do
        Magick[:legacy_demo].set_value(false)

        expect(versioning.rollback(:legacy_demo, 1)).to be true
        expect(Magick[:legacy_demo].enabled?).to be true
      end

      it 'appends above the old history without rewriting it' do
        appended = versioning.save_version(:legacy_demo)

        expect(appended.version).to eq(6)
        expect(MagickFeature.find_by(feature_name: legacy_store).data.keys)
          .to match_array(%w[version_1 version_2 version_3 version_4 version_5])
        expect(MagickFeature.exists?(feature_name: "#{legacy_store}#{described_class::ARCHIVE_ROW_INFIX}6")).to be true
      end
    end
  end
end
