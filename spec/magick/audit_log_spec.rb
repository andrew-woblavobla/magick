# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe Magick::AuditLog do
  let(:log) { described_class.new(nil, max_entries: 5) }

  it 'appends entries and returns the most recent first via limit' do
    5.times { |i| log.log(:demo, :set_value, changes: { value: i }) }
    expect(log.entries(limit: 3).map(&:changes)).to eq([{ value: 2 }, { value: 3 }, { value: 4 }])
  end

  it 'evicts the oldest entries once the cap is exceeded' do
    10.times { |i| log.log(:demo, :set_value, changes: { value: i }) }
    expect(log.size).to eq(5)
    expect(log.entries(limit: 10).first.changes).to eq({ value: 5 })
    expect(log.entries(limit: 10).last.changes).to eq({ value: 9 })
  end

  it 'defaults to DEFAULT_MAX_ENTRIES when no cap is supplied' do
    default_log = described_class.new
    expect(default_log.max_entries).to eq(Magick::AuditLog::DEFAULT_MAX_ENTRIES)
  end

  it 'defaults to DEFAULT_RETENTION for the durable store' do
    expect(described_class.new.retention).to eq(Magick::AuditLog::DEFAULT_RETENTION)
  end

  it 'filters by feature_name' do
    log.log(:a, :touch)
    log.log(:b, :touch)
    log.log(:a, :touch)
    expect(log.entries(feature_name: :a).size).to eq(2)
  end

  it 'is not durable when no adapter outlives the process' do
    expect(described_class.new.durable?).to be false
  end

  describe 'entry ids' do
    it 'stamps every entry with a unique, chronologically sortable id' do
      entries = 20.times.map { log.log(:demo, :touch) }
      ids = entries.map(&:id)

      expect(ids.uniq.size).to eq(20)
      expect(ids.sort).to eq(ids)
    end

    it 'round-trips an entry through its stored hash' do
      entry = log.log(:demo, :enable, user_id: 'admin-1', changes: { value: true }, metadata: { source: 'ui' })
      restored = Magick::AuditLog::Entry.from_h(JSON.parse(JSON.generate(entry.to_h)))

      expect(restored.id).to eq(entry.id)
      expect(restored.feature_name).to eq('demo')
      expect(restored.action).to eq('enable')
      expect(restored.user_id).to eq('admin-1')
      expect(restored.changes).to eq({ value: true })
      expect(restored.metadata).to eq({ source: 'ui' })
      expect(restored.timestamp.to_i).to eq(entry.timestamp.to_i)
    end
  end

  describe 'host-supplied adapter' do
    let(:sink_class) do
      Class.new do
        attr_reader :appended

        def initialize
          @appended = []
        end

        def append(entry)
          @appended << entry
        end
      end
    end

    it 'receives every entry' do
      sink = sink_class.new
      audit = described_class.new(sink)
      audit.log(:demo, :enable)
      expect(sink.appended.map(&:action)).to eq(['enable'])
    end

    it 'does not let an exploding adapter break the mutation' do
      exploding = Class.new do
        def append(_entry)
          raise 'sink down'
        end
      end.new
      audit = described_class.new(exploding)

      expect { audit.log(:demo, :enable) }.to output(/audit adapter/).to_stderr
      expect(audit.size).to eq(1)
    end
  end

  describe 'a shared, JSON-serializing backend' do
    # Mimics the Redis adapter: values are stored as JSON strings, so entries
    # come back with string keys rather than the symbol keys ActiveRecord hands
    # over. Standing in for one shared backend two processes both talk to.
    let(:shared_adapter) do
      Class.new do
        def initialize
          @store = {}
        end

        def get(feature_name, key)
          raw = @store.dig(feature_name.to_s, key.to_s)
          raw.is_a?(String) && raw.start_with?('[', '{') ? JSON.parse(raw) : raw
        end

        def set(feature_name, key, value)
          @store[feature_name.to_s] ||= {}
          @store[feature_name.to_s][key.to_s] = JSON.generate(value)
        end

        def load_all_features_data
          @store.each_with_object({}) do |(feature_name, data), out|
            out[feature_name] = data.transform_values { |v| JSON.parse(v) }
          end
        end
      end.new
    end

    it 'carries entries between two processes sharing it' do
      first = described_class.new(nil, adapter_registry: shared_adapter)
      second = described_class.new(nil, adapter_registry: shared_adapter)

      expect(first.durable?).to be true

      first.log(:checkout, :enable, user_id: 'admin-a', changes: { value: true })
      second.log(:checkout, :disable, user_id: 'admin-b')

      entry = first.entries(feature_name: :checkout).first
      expect(first.entries(feature_name: :checkout).map(&:action)).to eq(%w[enable disable])
      expect(second.entries(feature_name: :checkout).map(&:user_id)).to eq(%w[admin-a admin-b])
      expect(entry.changes).to eq({ value: true })
      expect(second.entries.map(&:feature_name)).to eq(%w[checkout checkout])
    end

    it 'restores an entry that lost a write race on this process\'s next write' do
      first = described_class.new(nil, adapter_registry: shared_adapter)
      second = described_class.new(nil, adapter_registry: shared_adapter)

      lost = first.log(:checkout, :enable)
      # Second process overwrites the shared list from a stale read, as a
      # simultaneous write from another container would.
      shared_adapter.set("#{described_class::STORE_PREFIX}checkout", 'entries', [])
      second.log(:checkout, :disable)

      first.log(:checkout, :set_value)
      expect(second.entries(feature_name: :checkout).map(&:id)).to include(lost.id)
    end
  end

  describe 'the ring lock' do
    it 'is released before the adapter is written, so the adapter can read the log' do
      observed = []
      adapter_class = Class.new do
        def initialize(observed, &reader)
          @observed = observed
          @reader = reader
        end

        def append(_entry)
          @observed << @reader.call
        end
      end

      audit = nil
      audit = described_class.new(adapter_class.new(observed) { audit.size })

      audit.log(:demo, :enable)
      expect(observed).to eq([1])
    end

    it 'does not serialize other mutations behind a slow adapter' do
      entered = Queue.new
      release = Queue.new
      blocking = Class.new do
        def initialize(entered, release)
          @entered = entered
          @release = release
        end

        def append(_entry)
          @entered << :in
          @release.pop
        end
      end.new(entered, release)

      audit = described_class.new(blocking)
      writers = []

      begin
        writers << Thread.new { audit.log(:slow, :enable) }
        entered.pop # the first adapter write is in flight

        # A second mutation reaches the adapter while the first is still
        # blocked in it: the ring lock is not held across adapter writes.
        writers << Thread.new { audit.log(:fast, :enable) }
        Timeout.timeout(5) { entered.pop }

        expect(audit.size).to eq(2)
      ensure
        2.times { release << :go }
        writers.each { |writer| writer.join(5) }
      end
    end
  end
end
