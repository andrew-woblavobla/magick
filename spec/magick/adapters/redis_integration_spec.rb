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

  it 'deletes a feature' do
    adapter.set(:gone, 'value', 1)
    adapter.delete(:gone)
    expect(adapter.exists?(:gone)).to be false
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
end
