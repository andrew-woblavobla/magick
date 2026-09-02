# frozen_string_literal: true

require 'spec_helper'

# Run these with `rake spec:redis` (or MAGICK_REDIS_SPECS=1 REDIS_URL=... rspec
# <this file>). See spec/support/redis.rb for why they get their own process.
RSpec.describe Magick::Adapters::Redis, 'integration', :redis, if: RedisSpecSupport.available? do
  let(:client) { RedisSpecSupport.new_client }
  let(:adapter) { described_class.new(client) }

  around do |ex|
    client.flushdb
    ex.run
    client.flushdb
  end

  it 'round-trips a value through hset/hget' do
    adapter.set(:foo, 'value', true)
    expect(adapter.get(:foo, 'value')).to be true
  end

  # Against a live server, not just the serialization logic: all three adapters
  # must hand nested structures back in the same shape (string keys at every
  # depth), or the same flag evaluates differently depending on which layer
  # served the read. See spec/magick/targeting_round_trip_spec.rb.
  it 'returns nested structures string-keyed at every depth' do
    adapter.set(:foo, 'targeting', { variants: [{ name: 'control', value: { copy: 'hello' } }] })

    expect(adapter.get(:foo, 'targeting')).to eq(
      { 'variants' => [{ 'name' => 'control', 'value' => { 'copy' => 'hello' } }] }
    )
  end

  it 'enumerates keys via SCAN' do
    adapter.set(:a, 'value', 1)
    adapter.set(:b, 'value', 2)
    expect(adapter.all_features).to match_array(%w[a b])
  end

  describe 'prefix-scoped bulk loads' do
    let(:reserved) { [Magick::Versioning::STORE_PREFIX, Magick::AuditLog::STORE_PREFIX] }

    before do
      adapter.set('billing', 'value', true)
      adapter.set("#{Magick::Versioning::STORE_PREFIX}billing", 'version_1', { 'version' => 1 })
      adapter.set("#{Magick::AuditLog::STORE_PREFIX}billing", 'entry_1', { 'action' => 'enable' })
    end

    it 'loads only the features under the prefix' do
      expect(adapter.load_features_data_with_prefix(Magick::Versioning::STORE_PREFIX).keys)
        .to eq(["#{Magick::Versioning::STORE_PREFIX}billing"])
    end

    # The hot window lives in Redis too, so a preload that did not filter here
    # would pull every cached snapshot into the worker alongside the features.
    it 'loads everything except the features under the reserved prefixes' do
      expect(adapter.load_features_data_without_prefixes(reserved).keys).to eq(['billing'])
    end

    it 'treats glob metacharacters in the prefix as literals' do
      adapter.set('a*b', 'value', true)
      adapter.set('axb', 'value', true)

      expect(adapter.load_features_data_with_prefix('a*').keys).to eq(['a*b'])
    end
  end

  it 'deletes a feature' do
    adapter.set(:gone, 'value', 1)
    adapter.delete(:gone)
    expect(adapter.exists?(:gone)).to be false
  end

  it 'removes a single hash field without touching the rest' do
    adapter.set(:multi, 'a', 1)
    adapter.set(:multi, 'b', 2)

    expect(adapter.delete_key(:multi, 'a')).to be true
    expect(adapter.get_all_data(:multi).keys).to eq(['b'])
    expect(adapter.delete_key(:multi, 'a')).to be false
  end

  describe '#next_sequence' do
    it 'hands out increasing numbers starting above the floor' do
      expect(adapter.next_sequence(:seq, 'sequence')).to eq(1)
      expect(adapter.next_sequence(:seq, 'sequence')).to eq(2)
    end

    it 'seeds a missing counter from the floor instead of restarting at 1' do
      expect(adapter.next_sequence(:seq, 'sequence', floor: 7)).to eq(8)
    end

    it 'jumps a counter that trails the floor past it' do
      adapter.next_sequence(:seq, 'sequence') # counter is now 1
      expect(adapter.next_sequence(:seq, 'sequence', floor: 20)).to be > 20
    end

    it 'never hands the same number to two clients of the same Redis' do
      clients = 4.times.map { described_class.new(RedisSpecSupport.new_client) }
      numbers = clients.flat_map do |client|
        Array.new(10) { Thread.new { client.next_sequence(:seq, 'sequence') } }
      end.map(&:value)

      expect(numbers.uniq.size).to eq(40)
      expect(numbers.sort).to eq((1..40).to_a)
    end
  end

  describe 'version history across processes' do
    it 'interleaves two containers into one history with no lost snapshots' do
      containers = 2.times.map do
        registry = Magick::Adapters::Registry.new(
          Magick::Adapters::Memory.new,
          described_class.new(RedisSpecSupport.new_client)
        )
        [registry, Magick::Versioning.new(registry)]
      end

      Magick.register_feature(:redis_versioned)
      feature = Magick.features['redis_versioned']

      3.times do |i|
        containers.each_with_index do |(_registry, versioning), container|
          versioning.record_change(feature, action: 'x', snapshot: { marker: "#{container}-#{i}" })
        end
      end

      views = containers.map do |_registry, versioning|
        versioning.get_versions(:redis_versioned).map { |v| [v.version, v.feature_data[:marker]] }
      end

      expect(views.first.map(&:first)).to eq((1..6).to_a)
      expect(views.last).to eq(views.first)
    ensure
      containers&.each { |registry, _versioning| registry.shutdown }
    end
  end

  it 'publishes cache invalidation that a second registry observes' do
    memory1 = Magick::Adapters::Memory.new
    memory2 = Magick::Adapters::Memory.new
    r1 = Magick::Adapters::Registry.new(memory1, described_class.new(RedisSpecSupport.new_client))
    r2 = Magick::Adapters::Registry.new(memory2, described_class.new(RedisSpecSupport.new_client))

    sleep 0.2 # let subscriber connect
    memory2.set(:foo, 'value', 'stale')
    r1.set(:foo, 'value', 'fresh')
    sleep 0.3 # allow Pub/Sub delivery

    expect(memory2.get(:foo, 'value')).to be_nil

    r1.shutdown
    r2.shutdown
  end

  # The async write path publishes only after the background write lands, so it
  # needs its own coverage — the sync example above would not catch a broken
  # gate there.
  it 'publishes cache invalidation from an async write too' do
    memory1 = Magick::Adapters::Memory.new
    memory2 = Magick::Adapters::Memory.new
    r1 = Magick::Adapters::Registry.new(memory1, described_class.new(RedisSpecSupport.new_client), async: true)
    r2 = Magick::Adapters::Registry.new(memory2, described_class.new(RedisSpecSupport.new_client))

    begin
      sleep 0.2 # let both subscribers connect
      memory2.set(:async_foo, 'value', 'stale')
      r1.set(:async_foo, 'value', 'fresh')

      wait_until { memory2.get(:async_foo, 'value').nil? }

      expect(memory2.get(:async_foo, 'value')).to be_nil
      expect(RedisSpecSupport.new_client.hget('magick:features:async_foo', 'value')).to eq('fresh')
    ensure
      r1.shutdown
      r2.shutdown
    end
  end

  # The regression this file exists to pin down: two containers toggling the
  # same flag close together. Suppression used to be keyed on "did I write this
  # feature in the last 2.0s", so r1 — having just written shared_flag — threw
  # away r2's invalidation and went on serving 'from_r1' while Redis held
  # 'from_r2'. Nothing healed it: an initialized value is only cleared by an
  # explicit reload. Keyed on the publisher, r1 acts on the peer's message and
  # r2 keeps the value it just wrote.
  it 'observes a peer write that lands well inside the old 2.0s suppression window' do
    memory1 = Magick::Adapters::Memory.new
    memory2 = Magick::Adapters::Memory.new
    r1 = Magick::Adapters::Registry.new(memory1, described_class.new(RedisSpecSupport.new_client))
    r2 = Magick::Adapters::Registry.new(memory2, described_class.new(RedisSpecSupport.new_client))

    begin
      sleep 0.2 # let both subscribers connect

      r1.set(:shared_flag, 'value', 'from_r1')
      r1_wrote_at = Time.now
      expect(memory1.get(:shared_flag, 'value')).to eq('from_r1')

      sleep 0.2 # let r1's own invalidation settle before the peer writes
      r2.set(:shared_flag, 'value', 'from_r2')
      expect(Time.now - r1_wrote_at).to be < 2.0 # the old suppression window

      wait_until { memory1.get(:shared_flag, 'value').nil? }

      # r1 dropped its diverged copy and reads the shared store again...
      expect(memory1.get(:shared_flag, 'value')).to be_nil
      expect(r1.get(:shared_flag, 'value')).to eq('from_r2')
      # ...while r2, the publisher, did not reload in response to its own write.
      expect(memory2.get(:shared_flag, 'value')).to eq('from_r2')
    ensure
      r1.shutdown
      r2.shutdown
    end
  end

  # Poll rather than sleep a fixed amount: Pub/Sub delivery is fast but not
  # instantaneous, and a fixed sleep is either flaky or needlessly slow.
  def wait_until(timeout: 2.0)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
  end
end
