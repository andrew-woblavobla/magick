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

  # Cross-process cache invalidation must never drop the FINAL state change.
  # enable/disable emits two publishes (targeting then value); a time-window
  # debounce would drop the second, leaving other containers stale for up to
  # the memory TTL. process_cache_invalidation reloads on EVERY valid message.
  describe '#process_cache_invalidation' do
    it 'processes a valid feature name' do
      expect(registry.send(:process_cache_invalidation, 'good_name')).to be true
    end

    it 'processes the same feature on consecutive invalidations (no trailing-message drop)' do
      expect(registry.send(:process_cache_invalidation, 'good_name')).to be true
      expect(registry.send(:process_cache_invalidation, 'good_name')).to be true
    end

    it 'rejects malformed feature names off the wire' do
      expect(registry.send(:process_cache_invalidation, "bad\nname")).to be false
      expect(registry.send(:process_cache_invalidation, 'x' * 200)).to be false
    end

    it 'skips self-invalidation for a feature this process just wrote' do
      registry.send(:record_local_write, 'mine')
      expect(registry.send(:process_cache_invalidation, 'mine')).to be false
    end
  end
end
