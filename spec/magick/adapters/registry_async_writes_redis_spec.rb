# frozen_string_literal: true

require 'spec_helper'

# Async writes against a real Redis: ordering and thread count are properties
# of the wire, so they are worth asserting outside the in-memory fakes.
#
# Run these with `rake spec:redis` (or MAGICK_REDIS_SPECS=1 REDIS_URL=... rspec
# <this file>). See spec/support/redis.rb for why they get their own process.
RSpec.describe Magick::Adapters::Registry, 'async writes (redis)', :redis,
               if: RedisSpecSupport.available? do
  let(:client) { RedisSpecSupport.new_client }
  let(:memory) { Magick::Adapters::Memory.new }
  # A connection of its own: the writer thread must not share one with the
  # example's client while it drains.
  let(:redis_adapter) { Magick::Adapters::Redis.new(RedisSpecSupport.new_client) }
  let(:registry) { described_class.new(memory, redis_adapter, async: true) }

  around do |ex|
    client.flushdb
    ex.run
    client.flushdb
  end

  after { registry.shutdown(timeout: 5) }

  it 'lands rapid writes to the same feature in the order they were issued' do
    # String values: the Redis adapter round-trips numbers as strings, and
    # this example is about ordering, not serialization.
    50.times { |i| registry.set(:ordered_flag, 'value', "v-#{i}") }

    registry.shutdown(timeout: 5)

    # Under thread-per-write, Redis could keep any of the 50 values while
    # memory kept the last one. Serialized, the last write always wins.
    expect(redis_adapter.get(:ordered_flag, 'value')).to eq('v-49')
    expect(memory.get(:ordered_flag, 'value')).to eq('v-49')
  end

  it 'leaves Redis and memory agreeing after concurrent writers' do
    threads = 8.times.map do |t|
      Thread.new { 10.times { |i| registry.set(:race_flag, 'value', "writer-#{t}-#{i}") } }
    end
    threads.each(&:join)

    registry.shutdown(timeout: 5)

    expect(redis_adapter.get(:race_flag, 'value')).to eq(memory.get(:race_flag, 'value'))
  end

  it 'spends one thread and one connection on a burst of writes' do
    registry.set(:burst_flag, 'value', 'start') # start the writer
    sleep 0.1
    before_threads = Thread.list.size

    200.times { |i| registry.set(:burst_flag, 'value', "v-#{i}") }

    expect(Thread.list.size - before_threads).to eq(0)

    registry.shutdown(timeout: 10)
    expect(redis_adapter.get(:burst_flag, 'value')).to eq('v-199')
  end

  it 'drains queued writes on shutdown' do
    20.times { |i| registry.set(:drain_flag, 'value', "v-#{i}") }

    registry.shutdown(timeout: 10)

    expect(registry.pending_async_writes).to eq(0)
    expect(redis_adapter.get(:drain_flag, 'value')).to eq('v-19')
  end
end
