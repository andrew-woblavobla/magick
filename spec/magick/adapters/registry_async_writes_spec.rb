# frozen_string_literal: true

require 'spec_helper'
require 'json'

# Fakes standing in for a Redis adapter + connection. The registry only needs
# a handful of methods, and going through Magick::Adapters::Memory keeps the
# stored values honest (a write that "lands" is really readable afterwards).
module AsyncWriteSpecSupport
  # A connection that records publishes and parks in #subscribe until the
  # registry unsubscribes/closes it — exactly what the real client does, so
  # the registry's subscriber thread starts and stops like it would in prod.
  class FakeConnection
    def initialize
      @published = []
      @mutex = Mutex.new
      @gate = Queue.new
    end

    def published
      @mutex.synchronize { @published.dup }
    end

    def publish(_channel, message)
      @mutex.synchronize { @published << message.to_s }
      1
    end

    def dup
      self.class.new
    end

    def subscribe(_channel)
      @gate.pop
      nil
    rescue ClosedQueueError
      nil
    end

    def unsubscribe(*)
      @gate.close unless @gate.closed?
    end

    def close
      @gate.close unless @gate.closed?
    end
  end

  # Memory-backed "Redis": records the order writes actually landed in, and can
  # be made slow (per-write delays) or wedged (a gate the writer blocks on).
  class RecordingRedisAdapter < Magick::Adapters::Memory
    attr_accessor :delays
    attr_reader :gate

    def initialize(delays: [], gate: nil)
      super()
      @delays = delays
      @gate = gate
      @writes = []
      @write_mutex = Mutex.new
      @connection = FakeConnection.new
    end

    def writes
      @write_mutex.synchronize { @writes.dup }
    end

    def client
      @connection
    end

    def set(feature_name, key, value)
      throttle
      @write_mutex.synchronize { @writes << [feature_name.to_s, key.to_s, value] }
      super
    end

    def set_all_data(feature_name, data_hash)
      throttle
      @write_mutex.synchronize { @writes << [feature_name.to_s, data_hash] }
      super
    end

    private

    def throttle
      @gate&.pop
      delay = @write_mutex.synchronize { @delays.shift }
      sleep delay if delay&.positive?
    end
  end
end

RSpec.describe Magick::Adapters::Registry, 'async writes' do
  let(:memory) { Magick::Adapters::Memory.new }
  let(:redis) { AsyncWriteSpecSupport::RecordingRedisAdapter.new }
  let(:registry) { new_registry }

  # Every write that does not reach Redis — failed, dropped or abandoned — is
  # reported through Magick::AdapterFailure. Captured rather than left to the
  # log so the assertions do not depend on whether a Rails logger exists in
  # the process (spec/rails_helper.rb boots one for the request specs).
  let(:reports) { [] }

  before do
    allow(Magick::AdapterFailure).to receive(:report) { |**args| reports << args }
  end

  # Tracked rather than shut down via the `registry` let, so an example that
  # never touches it does not pay to build and tear one down here.
  after { (@registries || []).each { |r| r.shutdown(timeout: 0.5) } }

  def new_registry(redis_adapter = redis, async: true, **options)
    registry = described_class.new(memory, redis_adapter, async: async, **options)
    (@registries ||= []) << registry
    registry
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    yield
  end

  describe 'serialization' do
    it 'drains writes through one writer thread instead of one thread per write' do
      registry.set('bulk_toggle', 'value', -1) # start the single writer
      expect(wait_until { registry.async_writer&.running? }).to be true
      before_threads = Thread.list.size

      200.times { |i| registry.set('bulk_toggle', 'value', i) }

      expect(Thread.list.size - before_threads).to eq(0)

      registry.shutdown(timeout: 5)
      expect(redis.writes.size).to eq(201)
    end

    it 'does not start a writer thread when async updates are off' do
      sync_registry = new_registry(async: false)
      sync_registry.set('sync_flag', 'value', true)

      expect(sync_registry.async_writer).to be_nil
      expect(redis.get('sync_flag', 'value')).to be true
    end
  end

  describe 'ordering' do
    it 'writes to the same feature reach Redis in the order they were issued' do
      # The first write is slow: under thread-per-write the second overtook it
      # and Redis was left holding the FIRST value while memory held the second.
      redis.delays = [0.08]

      registry.set('checkout_v2', 'value', 'first')
      registry.set('checkout_v2', 'value', 'second')
      registry.set('checkout_v2', 'value', 'third')

      registry.shutdown(timeout: 5)

      expect(redis.writes).to eq(
        [
          ['checkout_v2', 'value', 'first'],
          ['checkout_v2', 'value', 'second'],
          ['checkout_v2', 'value', 'third']
        ]
      )
      expect(redis.get('checkout_v2', 'value')).to eq('third')
      expect(memory.get('checkout_v2', 'value')).to eq('third')
    end

    it 'leaves memory and Redis holding the same value after concurrent writes' do
      redis.delays = Array.new(20) { 0.002 }

      threads = 20.times.map do |i|
        Thread.new { registry.set('race', 'value', i) }
      end
      threads.each(&:join)

      registry.shutdown(timeout: 5)

      expect(redis.get('race', 'value')).to eq(memory.get('race', 'value'))
      expect(redis.writes.size).to eq(20)
    end

    it 'orders bulk writes (set_all_data) through the same writer' do
      redis.delays = [0.05]

      registry.set_all_data('bulk', { 'value' => 1 })
      registry.set_all_data('bulk', { 'value' => 2 })

      registry.shutdown(timeout: 5)

      expect(redis.writes.map(&:last)).to eq([{ 'value' => 1 }, { 'value' => 2 }])
      expect(redis.get_all_data('bulk')).to eq({ 'value' => 2 })
    end

    it 'publishes cache invalidation after each write, in the same order' do
      redis.delays = [0.05]

      registry.set('a_flag', 'value', 1)
      registry.set('b_flag', 'value', 2)

      registry.shutdown(timeout: 5)

      # Invalidation messages are JSON carrying the publishing registry's
      # identity; what this example pins is that there is one per write and
      # that they leave in the order the writes were issued.
      published = redis.client.published.map { |message| JSON.parse(message) }
      expect(published.map { |message| message['feature'] }).to eq(%w[a_flag b_flag])
      expect(published.map { |message| message['publisher'] }).to all(eq(registry.publisher_id))
    end
  end

  describe 'bounded queue' do
    let(:gate) { Queue.new }
    let(:redis) { AsyncWriteSpecSupport::RecordingRedisAdapter.new(gate: gate) }
    let(:registry) { new_registry(async_queue_limit: 2, async_enqueue_timeout: 0.01) }

    after { gate.close unless gate.closed? }

    it 'applies the configured bound and reports the writes it drops' do
      # Wedge the writer inside its first Redis write, then overflow the queue.
      registry.set('wedged', 'value', 0)
      expect(wait_until { registry.async_writer&.running? }).to be true

      8.times { |i| registry.set('wedged', 'value', i + 1) }

      expect(registry.async_writer.queue_limit).to eq(2)
      expect(registry.pending_async_writes).to be <= 2
      expect(registry.async_writer.stats[:dropped]).to be_positive

      # A dropped write never reaches Redis, so it is reported like any other
      # failed backend write rather than warned about in passing.
      drop_report = reports.find { |r| r[:reason].to_s.include?('async write queue full') }
      expect(drop_report).to include(backend: :redis, operation: :async_write, feature_name: 'wedged')
      expect(drop_report[:reason]).to include('limit 2', 'dropped so far')

      # Memory still holds the newest value — reads stay correct while Redis
      # is wedged; the drop is visible, not silent.
      expect(memory.get('wedged', 'value')).to eq(8)
    end

    it 'holds threads constant even while the queue overflows' do
      registry.set('wedged', 'value', 0)
      expect(wait_until { registry.async_writer&.running? }).to be true
      before_threads = Thread.list.size

      25.times { |i| registry.set('wedged', 'value', i + 1) }

      expect(Thread.list.size - before_threads).to eq(0)
    end
  end

  describe 'shutdown' do
    it 'drains pending writes before returning' do
      redis.delays = Array.new(10) { 0.01 }
      10.times { |i| registry.set('drain_me', 'value', i) }

      registry.shutdown(timeout: 5)

      expect(redis.writes.size).to eq(10)
      expect(registry.pending_async_writes).to eq(0)
      expect(registry.async_writer.running?).to be false
    end

    it 'abandons the backlog within the timeout rather than hanging' do
      gate = Queue.new # never released: Redis is wedged
      wedged_redis = AsyncWriteSpecSupport::RecordingRedisAdapter.new(gate: gate)
      wedged_registry = new_registry(wedged_redis)

      5.times { |i| wedged_registry.set('wedged', 'value', i) }
      expect(wait_until { wedged_registry.pending_async_writes.positive? }).to be true

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      wedged_registry.shutdown(timeout: 0.2)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 3
      abandon_report = reports.find { |r| r[:reason].to_s.include?('abandoned') }
      expect(abandon_report).to include(backend: :redis, operation: :async_write)
      expect(abandon_report[:reason]).to include('abandoned 4 pending write(s)')
      expect(wedged_registry.async_writer.running?).to be false
      expect(wedged_registry.pending_async_writes).to eq(0)

      gate.close
    end

    it 'writes inline after shutdown instead of losing the write' do
      registry.shutdown(timeout: 0.3)

      registry.set('after_shutdown', 'value', 'landed')

      expect(redis.get('after_shutdown', 'value')).to eq('landed')
      expect(redis.writes.size).to eq(1)
    end
  end

  describe 'configuration' do
    it 'carries the DSL bounds through to the writer' do
      config = Magick::Config.new
      config.async_updates(enabled: true, queue_limit: 5, enqueue_timeout: 0.25)
      config.adapter(:registry)

      configured = config.adapter_registry
      (@registries ||= []) << configured
      configured.instance_variable_set(:@redis_adapter, redis)
      configured.set('configured', 'value', true)

      expect(configured.async_writer.queue_limit).to eq(5)
      expect(configured.async_writer.enqueue_timeout).to eq(0.25)
    end

    it 'defaults to the writer bounds when the DSL sets none' do
      registry.set('defaulted', 'value', true)

      expect(registry.async_writer.queue_limit).to eq(Magick::Adapters::AsyncWriter::DEFAULT_QUEUE_LIMIT)
      expect(registry.async_writer.enqueue_timeout).to eq(Magick::Adapters::AsyncWriter::DEFAULT_ENQUEUE_TIMEOUT)
    end
  end
end
