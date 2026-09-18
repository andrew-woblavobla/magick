# frozen_string_literal: true

require 'spec_helper'

# The periodic source refresh (ADR-0002): what bounds how stale a process can
# be when a Pub/Sub invalidation never reaches it. A second Memory adapter
# stands in for the shared ActiveRecord/Redis backend, exactly as the
# #authoritative_get_all_data specs do.
RSpec.describe Magick::Adapters::Registry, 'source refresh' do
  let(:memory) { Magick::Adapters::Memory.new }
  let(:source) { Magick::Adapters::Memory.new }
  let(:registry) { described_class.new(memory, active_record_adapter: source, refresh_interval: 0.05) }

  # A source that counts bulk reads, to prove how often it is hit.
  let(:counting_source_class) do
    Class.new(Magick::Adapters::Memory) do
      attr_reader :loads

      def load_all_features_data
        @loads = (@loads || 0) + 1
        super
      end
    end
  end

  # A source that is down.
  let(:broken_source_class) do
    Class.new(Magick::Adapters::Memory) do
      def load_all_features_data
        raise Magick::AdapterError, 'connection refused'
      end
    end
  end

  describe '#refresh_from_source!' do
    it 'writes a feature whose stored state changed into the local cache and names it' do
      source.set_all_data(:flag, { 'value' => false })
      registry.refresh_from_source!
      source.set_all_data(:flag, { 'value' => true })

      expect(registry.refresh_from_source!).to eq(['flag'])
      expect(memory.get(:flag, 'value')).to be true
    end

    it 'reloads the registered Feature, so its in-object state follows the store' do
      Magick.adapter_registry = registry
      source.set_all_data(:flag, { 'value' => false })
      feature = Magick.register_feature(:flag)
      registry.refresh_from_source!
      expect(feature.enabled?).to be false

      # A write nobody published — an ops tool, a script, a direct store edit.
      source.set_all_data(:flag, { 'value' => true, 'targeting' => { 'user' => ['42'] } })
      registry.refresh_from_source!

      expect(feature.enabled?(user_id: '42')).to be true
      expect(feature.enabled?(user_id: '7')).to be false
      expect(feature.targeting).to eq({ user: ['42'] })
    end

    it 'measures the first read against the local cache' do
      memory.set_all_data(:flag, { 'value' => false }) # stale local copy
      source.set_all_data(:flag, { 'value' => true })

      expect(registry.refresh_from_source!).to eq(['flag'])
      expect(memory.get(:flag, 'value')).to be true
    end

    it 'reports nothing when the store still holds what it held last time' do
      source.set_all_data(:flag, { 'value' => true })
      registry.refresh_from_source!

      expect(registry.refresh_from_source!).to eq([])
    end

    # A local write in flight: memory is ahead of the shared store (an async
    # Redis write still queued, or the AR write a few instructions away). The
    # store has not changed since we last read it, so the feature is left alone.
    it 'never reverts a local write that has not reached the store yet' do
      source.set_all_data(:flag, { 'value' => false })
      registry.refresh_from_source!
      memory.set_all_data(:flag, { 'value' => true })

      expect(registry.refresh_from_source!).to eq([])
      expect(memory.get(:flag, 'value')).to be true
    end

    it 'picks the local write up as a no-op change once it lands in the store' do
      source.set_all_data(:flag, { 'value' => false })
      registry.refresh_from_source!
      memory.set_all_data(:flag, { 'value' => true })
      source.set_all_data(:flag, { 'value' => true })

      expect(registry.refresh_from_source!).to eq(['flag'])
      expect(memory.get(:flag, 'value')).to be true
    end

    # A partial view from the backend (one adapter reachable, the other not;
    # ActiveRecord half backfilled) must not be able to strip live features.
    # Deleting through the gem publishes an invalidation, which does evict.
    it 'does not evict a feature that vanished from the source' do
      source.set_all_data(:flag, { 'value' => true })
      registry.refresh_from_source!
      source.delete(:flag)

      expect(registry.refresh_from_source!).to eq([])
      expect(memory.get(:flag, 'value')).to be true
    end

    it 'keeps version snapshots and audit history out of the feature cache' do
      source.set_all_data(:flag, { 'value' => true })
      source.set_all_data("#{Magick::Versioning::STORE_PREFIX}flag", { 'version_1' => { 'version' => 1 } })
      source.set_all_data("#{Magick::AuditLog::STORE_PREFIX}flag", { 'entry_1' => { 'action' => 'enable' } })

      expect(registry.refresh_from_source!).to eq(['flag'])
      expect(memory.all_features).to eq(['flag'])
    end

    it 'touches nothing and returns nil when no source answers' do
      memory.set_all_data(:flag, { 'value' => true })
      registry = described_class.new(memory, active_record_adapter: broken_source_class.new)

      expect(registry.refresh_from_source!).to be_nil
      expect(memory.get(:flag, 'value')).to be true
    end

    it 'returns nil without a shared backend to read from' do
      expect(described_class.new(memory).refresh_from_source!).to be_nil
    end

    it 'never raises, and reports an unexpected failure like any other adapter failure' do
      allow(Magick::AdapterFailure).to receive(:report)
      Magick.adapter_registry = registry
      source.set_all_data(:flag, { 'value' => true })
      feature = Magick.register_feature(:flag)
      allow(feature).to receive(:reload).and_raise(RuntimeError, 'boom')
      source.set_all_data(:flag, { 'value' => false })

      expect { registry.refresh_from_source! }.not_to raise_error
      expect(Magick::AdapterFailure).to have_received(:report)
        .with(backend: :active_record, operation: :refresh, error: an_instance_of(RuntimeError))
    end
  end

  describe '#refresh_if_stale!' do
    let(:source) { counting_source_class.new }

    it 'reads the source on the first call and then not again until the interval has elapsed' do
      source.set_all_data(:flag, { 'value' => true })

      registry.refresh_if_stale!
      registry.refresh_if_stale!
      registry.refresh_if_stale!
      expect(source.loads).to eq(1)

      sleep 0.06
      registry.refresh_if_stale!
      expect(source.loads).to eq(2)
    end

    it 'lets exactly one of many concurrent evaluations pay for the read' do
      source.set_all_data(:flag, { 'value' => true })

      threads = Array.new(16) { Thread.new { registry.refresh_if_stale! } }
      threads.each(&:join)

      expect(source.loads).to eq(1)
    end

    it 'probes a failing source once per interval, not once per evaluation' do
      failing = Class.new(counting_source_class) do
        def load_all_features_data
          super
          raise Magick::AdapterError, 'connection refused'
        end
      end.new
      registry = described_class.new(memory, active_record_adapter: failing, refresh_interval: 0.05)

      5.times { registry.refresh_if_stale! }

      expect(failing.loads).to eq(1)
    end

    it 'is off when the interval is nil' do
      registry.refresh_interval = nil

      expect(registry.refresh_if_stale!).to be_nil
      expect(source.loads).to be_nil
    end

    it 'is off when the interval is false' do
      registry.refresh_interval = false

      expect(registry.refresh_if_stale!).to be_nil
      expect(source.loads).to be_nil
    end

    it 'is off when the interval is zero' do
      registry.refresh_interval = 0

      expect(registry.refresh_if_stale!).to be_nil
      expect(source.loads).to be_nil
    end

    it 'does nothing in memory-only mode, where there is nothing to converge on' do
      registry = described_class.new(memory, refresh_interval: 0.05)

      expect(registry.refresh_if_stale!).to be_nil
    end
  end

  describe '#refresh_interval' do
    it 'defaults to DEFAULT_REFRESH_INTERVAL' do
      expect(described_class.new(memory).refresh_interval).to eq(described_class::DEFAULT_REFRESH_INTERVAL)
    end

    it 'accepts a number of seconds' do
      registry.refresh_interval = 15
      expect(registry.refresh_interval).to eq(15.0)
    end

    it 'treats nil, false and non-positive numbers as off' do
      [nil, false, 0, -1].each do |off|
        registry.refresh_interval = off
        expect(registry.refresh_interval).to be_nil
      end
    end

    it 'rejects anything that is not a number of seconds' do
      expect { registry.refresh_interval = 'soon' }.to raise_error(ArgumentError, /refresh_interval/)
    end
  end

  describe '#health' do
    it 'reports the refresh configuration and the last confirmed read' do
      expect(registry.health).to include(
        redis: false,
        active_record: true,
        subscriber_running: false,
        subscriber_last_error: nil,
        refresh_interval: 0.05,
        last_source_refresh_at: nil,
        pending_async_writes: 0
      )

      registry.refresh_from_source!

      expect(registry.health[:last_source_refresh_at]).to be_within(1).of(Time.now)
    end
  end

  describe '#subscriber_running?' do
    it 'is false without Redis' do
      expect(described_class.new(memory).subscriber_running?).to be false
    end
  end
end
