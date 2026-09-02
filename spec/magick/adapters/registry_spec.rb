# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Adapters::Registry do
  let(:memory_adapter) { Magick::Adapters::Memory.new }
  let(:registry) { described_class.new(memory_adapter) }

  describe '#get' do
    it 'retrieves from memory adapter' do
      memory_adapter.set(:test_feature, 'value', true)
      expect(registry.get(:test_feature, 'value')).to be true
    end

    it 'returns nil when not found' do
      expect(registry.get(:non_existent, 'value')).to be_nil
    end
  end

  describe '#set' do
    it 'sets value in memory adapter' do
      registry.set(:test_feature, 'value', true)
      expect(memory_adapter.get(:test_feature, 'value')).to be true
    end
  end

  describe '#delete' do
    it 'deletes from memory adapter' do
      registry.set(:test_feature, 'value', true)
      registry.delete(:test_feature)
      expect(registry.exists?(:test_feature)).to be false
    end
  end

  # The gem's documented contract is that a flag lookup never raises. exists?
  # and all_features are reached from outside the fail-safe evaluation path
  # (Admin UI, export, dependency checks), so a backend outage has to read as
  # "not there", not as a 500.
  describe 'fail-safe reads when a backend is unavailable' do
    let(:broken) do
      instance_double(Magick::Adapters::Redis).tap do |a|
        allow(a).to receive(:exists?).and_raise(Magick::AdapterError, 'Redis down')
        allow(a).to receive(:all_features).and_raise(Magick::AdapterError, 'Redis down')
        # An unreachable backend cannot hand out a connection either.
        allow(a).to receive(:client).and_raise(Magick::AdapterError, 'Redis down')
      end
    end
    let(:registry) { described_class.new(memory_adapter, broken) }

    after { registry.shutdown(timeout: 0.1) }

    it 'returns false from exists? rather than propagating the adapter error' do
      expect { registry.exists?(:anything) }.not_to raise_error
      expect(registry.exists?(:anything)).to be false
    end

    it 'still reports what the healthy adapters know' do
      memory_adapter.set(:local_flag, 'value', true)
      expect(registry.exists?(:local_flag)).to be true
      expect(registry.all_features).to eq(['local_flag'])
    end
  end

  # The Admin UI must render the true current state even when the toggle was
  # written by a *different* process/container (load-balanced redirect). These
  # methods read straight from the shared backend, bypassing this process's
  # possibly-stale local memory cache. A second Memory adapter stands in for
  # the shared ActiveRecord/Redis backend.
  describe '#authoritative_get_all_data' do
    let(:source_adapter) { Magick::Adapters::Memory.new }
    let(:registry) { described_class.new(memory_adapter, active_record_adapter: source_adapter) }

    it 'returns fresh state from the shared source, bypassing a stale local cache' do
      memory_adapter.set_all_data(:flag, { 'value' => false })   # stale local copy
      source_adapter.set_all_data(:flag, { 'value' => true })    # authoritative copy

      data = registry.authoritative_get_all_data(:flag)

      expect(data['value']).to be true
    end

    it 'refreshes the local memory cache with the authoritative state' do
      memory_adapter.set_all_data(:flag, { 'value' => false })
      source_adapter.set_all_data(:flag, { 'value' => true })

      registry.authoritative_get_all_data(:flag)

      expect(memory_adapter.get(:flag, 'value')).to be true
    end

    it 'falls back to the local cache when the source has no data' do
      memory_adapter.set_all_data(:flag, { 'value' => true })

      expect(registry.authoritative_get_all_data(:flag)['value']).to be true
    end
  end

  describe '#refresh_all_from_source' do
    let(:source_adapter) { Magick::Adapters::Memory.new }
    let(:registry) { described_class.new(memory_adapter, active_record_adapter: source_adapter) }

    it 'overwrites the local memory cache for every feature from the shared source' do
      memory_adapter.set_all_data(:a, { 'value' => false })
      source_adapter.set_all_data(:a, { 'value' => true })
      source_adapter.set_all_data(:b, { 'value' => true })

      registry.refresh_all_from_source

      expect(memory_adapter.get(:a, 'value')).to be true
      expect(memory_adapter.get(:b, 'value')).to be true
    end
  end

  # Cross-process cache invalidation must never drop a peer's change. Suppression
  # is keyed on WHO published the message: a registry drops exactly its own echo
  # and acts on every peer message, no matter how recently it wrote that feature
  # itself. (A time window keyed on "did I write this recently" dropped peer
  # messages too, so two containers toggling one flag inside the window each kept
  # serving their own value.) Every acted-on message reloads the feature's full
  # state, so repeats are idempotent.
  describe '#process_cache_invalidation' do
    let(:peer) { described_class.new(Magick::Adapters::Memory.new) }

    def message_from(publisher, feature_name)
      JSON.generate('feature' => feature_name, 'publisher' => publisher)
    end

    it 'acts on a peer message' do
      expect(registry.send(:process_cache_invalidation, message_from('peer-1', 'good_name'))).to be true
    end

    it 'processes the same feature on consecutive invalidations (no trailing-message drop)' do
      expect(registry.send(:process_cache_invalidation, message_from('peer-1', 'good_name'))).to be true
      expect(registry.send(:process_cache_invalidation, message_from('peer-1', 'good_name'))).to be true
    end

    it 'rejects malformed feature names off the wire' do
      expect(registry.send(:process_cache_invalidation, message_from('peer-1', "bad\nname"))).to be false
      expect(registry.send(:process_cache_invalidation, message_from('peer-1', 'x' * 200))).to be false
    end

    it 'rejects payloads that are not an invalidation message' do
      expect(registry.send(:process_cache_invalidation, '{"feature":')).to be false
      expect(registry.send(:process_cache_invalidation, JSON.generate(%w[not a hash]))).to be false
      expect(registry.send(:process_cache_invalidation, "{\"feature\":\"#{'x' * 600}\"}")).to be false
    end

    it 'ignores the message it publishes for its own write' do
      own_message = registry.send(:invalidation_message, 'mine')

      expect(registry.send(:process_cache_invalidation, own_message)).to be false
    end

    it 'acts on the same message when a different registry published it' do
      peer_message = peer.send(:invalidation_message, 'mine')

      expect(registry.send(:process_cache_invalidation, peer_message)).to be true
    end

    it 'acts on a peer message for a feature it wrote itself a moment ago' do
      registry.set('mine', 'value', true)

      expect(registry.send(:process_cache_invalidation, peer.send(:invalidation_message, 'mine'))).to be true
    end

    it 'clears the local cache entry a peer invalidated, even right after a local write' do
      registry.set('mine', 'value', true)

      registry.send(:process_cache_invalidation, peer.send(:invalidation_message, 'mine'))

      expect(memory_adapter.get('mine', 'value')).to be_nil
    end

    it 'acts on a bare feature name published by an older process' do
      expect(registry.send(:process_cache_invalidation, 'good_name')).to be true
    end
  end

  # The publisher id is the whole basis of self-suppression: it must be unique
  # per registry, stable for the life of the process, and re-minted after a fork
  # so a parent and its worker never ignore each other's invalidations.
  describe '#publisher_id' do
    it 'is stable across calls' do
      expect(registry.publisher_id).to eq(registry.publisher_id)
    end

    it 'differs between two registries in the same process' do
      expect(registry.publisher_id).not_to eq(described_class.new(Magick::Adapters::Memory.new).publisher_id)
    end

    it 'is re-minted in a forked child', if: Process.respond_to?(:fork) do
      parent_id = registry.publisher_id
      reader, writer = IO.pipe

      pid = fork do
        reader.close
        writer.write(registry.publisher_id)
        writer.close
        exit!(0)
      end
      writer.close
      child_id = reader.read
      reader.close
      Process.wait(pid)

      expect(child_id).not_to eq(parent_id)
    end
  end
end
