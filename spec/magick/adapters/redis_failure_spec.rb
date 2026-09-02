# frozen_string_literal: true

require 'spec_helper'
require 'socket'

# Run with `bundle exec rake spec:redis`. See spec/support/redis.rb for why the
# Redis-tagged examples get their own process.
#
# The gate asks for a *reachable* Redis — that is what makes this a Redis run at
# all, and the last example needs a live server to prove the peer side. What is
# under test, though, is the unreachable case, so most examples build their own
# clients pointed at a port nothing is listening on.
RSpec.describe 'Redis failure degrades gracefully', :redis, if: RedisSpecSupport.available? do
  # Ask the kernel for a free port, then hand it straight back. Connecting to it
  # fails immediately instead of hanging, which keeps these examples fast.
  let(:dead_url) do
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    "redis://127.0.0.1:#{port}/0"
  end

  let(:client) { ::Redis.new(url: dead_url, **Magick::Adapters::Redis::DEFAULT_TIMEOUTS) }
  let(:redis_adapter) { Magick::Adapters::Redis.new(client) }
  let(:memory) { Magick::Adapters::Memory.new }
  let(:breaker) { Magick::CircuitBreaker.new(failure_threshold: 2, timeout: 60) }
  let(:registry) { Magick::Adapters::Registry.new(memory, redis_adapter, circuit_breaker: breaker) }

  before { allow(client).to receive(:publish).and_call_original }

  after { registry.shutdown(timeout: 0.2) }

  describe 'the write path' do
    it 'publishes no cache invalidation when the Redis write fails' do
      expect { registry.set('checkout', 'value', true) }.not_to raise_error
      expect(client).not_to have_received(:publish)
    end

    it 'publishes no cache invalidation once the circuit is open' do
      2.times { registry.set('checkout', 'value', true) } # trips the breaker
      expect(breaker.state).to eq(:open)

      expect { registry.set('checkout', 'value', false) }.not_to raise_error
      expect(client).not_to have_received(:publish)
    end

    it 'publishes no cache invalidation from a bulk write or a delete' do
      expect { registry.set_all_data('checkout', { 'value' => true }) }.not_to raise_error
      expect { registry.delete('checkout') }.not_to raise_error
      expect(client).not_to have_received(:publish)
    end

    it 'publishes nothing on the async write path either' do
      async = Magick::Adapters::Registry.new(memory, redis_adapter, circuit_breaker: breaker, async: true)
      async.set('checkout', 'value', true)
      sleep 0.3 # a refused connection resolves immediately; this is slack

      expect(client).not_to have_received(:publish)
    ensure
      async&.shutdown(timeout: 0.2)
    end

    it 'still applies the toggle locally so the process keeps serving flags' do
      registry.set('checkout', 'value', true)
      expect(memory.get('checkout', 'value')).to be true
      expect(registry.get('checkout', 'value')).to be true
    end
  end

  describe 'the read path' do
    it 'answers every read without raising' do
      expect { registry.get('checkout', 'value') }.not_to raise_error
      expect(registry.get('checkout', 'value')).to be_nil
      expect(registry.get_all_data('checkout')).to eq({})
      expect(registry.all_features).to eq([])
      expect(registry.preload!).to eq({})
      expect(registry.authoritative_get_all_data('checkout')).to eq({})
    end

    it 'returns false from exists? rather than propagating the adapter error' do
      expect { registry.exists?('checkout') }.not_to raise_error
      expect(registry.exists?('checkout')).to be false
    end

    it 'goes through the breaker, so a dead Redis is contacted once per window, not once per read' do
      allow(client).to receive(:hget).and_call_original

      2.times { registry.get('checkout', 'value') }
      expect(breaker.state).to eq(:open)
      expect(client).to have_received(:hget).twice

      5.times { registry.get('checkout', 'value') }
      expect(client).to have_received(:hget).twice # short-circuited, never re-attempted
    end
  end

  # The failure mode this ticket exists for. A Redis blip trips the breaker;
  # Redis then recovers, but the breaker stays open for its timeout. During that
  # window a toggle cannot reach Redis — so it must not tell peers to reload,
  # because what they would reload is the pre-toggle value.
  describe 'an open circuit while Redis itself is healthy' do
    let(:writer_client) { RedisSpecSupport.new_client }
    let(:peer_memory) { Magick::Adapters::Memory.new }
    let(:writer) do
      Magick::Adapters::Registry.new(
        Magick::Adapters::Memory.new,
        Magick::Adapters::Redis.new(writer_client),
        circuit_breaker: breaker
      )
    end
    let(:peer) do
      Magick::Adapters::Registry.new(peer_memory, Magick::Adapters::Redis.new(RedisSpecSupport.new_client))
    end

    around do |ex|
      RedisSpecSupport.new_client.flushdb
      ex.run
      RedisSpecSupport.new_client.flushdb
    end

    after do
      writer.shutdown(timeout: 0.2)
      peer.shutdown(timeout: 0.2)
    end

    it 'does not invalidate peers into reloading the pre-toggle value' do
      allow(writer_client).to receive(:publish).and_call_original

      # Redis — and therefore every peer — is holding the pre-toggle value.
      RedisSpecSupport.new_client.hset('magick:features:blip', 'value', 'false')
      peer_memory.set('blip', 'value', false)
      peer # force the subscriber to start
      sleep 0.2 # let it connect

      2.times { breaker.call { raise 'redis blip' } rescue nil } # the blip, now over
      expect(breaker.state).to eq(:open)

      writer.set('blip', 'value', true)
      sleep 0.3 # far more than Pub/Sub needs locally

      expect(writer_client).not_to have_received(:publish)
      # Still the pre-toggle value, not wiped by a bogus invalidation — and
      # nothing raised on the way here.
      expect(peer_memory.get('blip', 'value')).to be false
    end
  end
end

# Separate top-level group on purpose: the group above builds Redis clients in
# its own before/after hooks, which the `::Redis.new` message expectation below
# would otherwise count.
RSpec.describe 'Redis client defaults', :redis, if: RedisSpecSupport.available? do
  let(:timeouts) { Magick::Adapters::Redis::DEFAULT_TIMEOUTS }

  it 'constructs the default client with explicit connect, read and write timeouts' do
    expect(::Redis).to receive(:new).with(
      hash_including(
        connect_timeout: kind_of(Numeric),
        read_timeout: kind_of(Numeric),
        write_timeout: kind_of(Numeric)
      )
    ).and_call_original

    Magick::Adapters::Redis.new
  end

  it "really carries those timeouts, rather than redis-rb's 5s defaults" do
    config = Magick::Adapters::Redis.new.client._client.config

    expect(config.connect_timeout).to eq(timeouts[:connect_timeout])
    expect(config.read_timeout).to eq(timeouts[:read_timeout])
    expect(config.write_timeout).to eq(timeouts[:write_timeout])
  end

  it 'applies the same timeouts through the config DSL, and lets them be overridden' do
    adapter = Magick::Config.new.send(:configure_redis_adapter, url: RedisSpecSupport.url, read_timeout: 4.0)
    config = adapter.client._client.config

    expect(config.connect_timeout).to eq(timeouts[:connect_timeout])
    expect(config.read_timeout).to eq(4.0)
    expect(config.write_timeout).to eq(timeouts[:write_timeout])
  end
end
