# frozen_string_literal: true

require 'spec_helper'

begin
  require 'redis'
rescue LoadError
  # redis gem not installed; whole file will be skipped below
end

RSpec.describe Magick::Adapters::Redis, 'integration', if: ENV['REDIS_URL'] && defined?(::Redis) do
  let(:client) { ::Redis.new(url: ENV.fetch('REDIS_URL')) }
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
    r1 = Magick::Adapters::Registry.new(memory1, described_class.new(::Redis.new(url: ENV.fetch('REDIS_URL'))))
    r2 = Magick::Adapters::Registry.new(memory2, described_class.new(::Redis.new(url: ENV.fetch('REDIS_URL'))))

    sleep 0.2 # let subscriber connect
    memory2.set(:foo, 'value', 'stale')
    r1.set(:foo, 'value', 'fresh')
    sleep 0.3 # allow Pub/Sub delivery

    expect(memory2.get(:foo, 'value')).to be_nil

    r1.shutdown
    r2.shutdown
  end
end
