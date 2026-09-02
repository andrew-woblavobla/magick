# frozen_string_literal: true

require 'spec_helper'

# Minimal Redis stand-in for the stats keyspace. Values are strings, as the
# real client returns, and KEYS is deliberately fatal: the stats paths must
# enumerate with the cursor-based SCAN instead.
class StatsRedisDouble
  attr_reader :store, :scan_calls
  attr_accessor :fail_writes

  def initialize
    @store = {}
    @scan_calls = 0
    @fail_writes = false
  end

  def keys(*)
    raise 'KEYS blocks the Redis server; stats paths must enumerate with SCAN'
  end

  def scan(cursor, match:, count: 10)
    @scan_calls += 1
    matching = @store.keys.grep(pattern_to_regexp(match)).sort
    offset = cursor.to_i
    page = matching[offset, count] || []
    next_offset = offset + count
    [next_offset >= matching.length ? '0' : next_offset.to_s, page]
  end

  def get(key)
    @store[key]
  end

  def incrby(key, amount)
    refuse_write!(key)
    @store[key] = (@store[key].to_i + amount).to_s
  end

  def incrbyfloat(key, amount)
    refuse_write!(key)
    @store[key] = (@store[key].to_f + amount).to_s
  end

  def expire(_key, _ttl)
    true
  end

  private

  def refuse_write!(key)
    return unless @fail_writes == true || (@fail_writes.is_a?(Array) && @fail_writes.include?(key))

    raise Errno::ECONNREFUSED, 'stats write'
  end

  def pattern_to_regexp(pattern)
    /\A#{pattern.split('*', -1).map { |part| Regexp.escape(part) }.join('.*')}\z/
  end
end

RSpec.describe Magick::PerformanceMetrics do
  let(:registry) { Magick::Adapters::Registry.new(Magick::Adapters::Memory.new) }
  let(:redis) { StatsRedisDouble.new }

  before do
    @instances = []
    Magick.adapter_registry = registry
  end

  after do
    @instances.each(&:stop_async_processor)
  end

  # The async processor is stopped so specs can drive process_async_record
  # directly; batching thresholds are pushed out of the way so only the
  # flushes a spec asks for actually happen.
  def build_metrics(async: false, **opts)
    metrics = described_class.new(**{ batch_size: 100_000, flush_interval: 3_600 }.merge(opts))
    @instances << metrics
    metrics.stop_async_processor unless async
    metrics
  end

  def record_sync(metrics, feature_name, operation = 'enabled?', duration = 1.0, success: true)
    metrics.process_async_record(feature_name, operation, duration, success)
  end

  def with_redis
    allow(registry).to receive(:redis_available?).and_return(true)
    allow(registry).to receive(:redis_client).and_return(redis)
  end

  describe 'usage counts without Redis' do
    it 'reports every recorded call on the first read' do
      metrics = build_metrics
      5.times { record_sync(metrics, 'alpha') }

      expect(metrics.usage_count('alpha')).to eq(5)
    end

    it 'keeps reporting them on repeated reads' do
      metrics = build_metrics
      5.times { record_sync(metrics, 'alpha') }

      expect([metrics.usage_count('alpha'), metrics.usage_count('alpha')]).to eq([5, 5])
    end

    it 'leaves the updates pending rather than crediting them as flushed' do
      metrics = build_metrics
      3.times { record_sync(metrics, 'alpha') }
      metrics.force_flush_to_redis

      expect(metrics.instance_variable_get(:@pending_updates)['alpha']).to eq(3)
      expect(metrics.instance_variable_get(:@flushed_counts)['alpha']).to eq(0)
    end

    it 'reports durations from memory' do
      metrics = build_metrics
      record_sync(metrics, 'alpha', 'enabled?', 2.0)
      record_sync(metrics, 'alpha', 'enabled?', 4.0)

      expect(metrics.average_duration(feature_name: 'alpha')).to eq(3.0)
    end

    it 'counts calls made through the async record path' do
      metrics = build_metrics(async: true)
      5.times { metrics.record('alpha', 'enabled?', 1.0) }

      deadline = Time.now + 5
      sleep 0.01 while metrics.usage_count('alpha') < 5 && Time.now < deadline

      expect(metrics.usage_count('alpha')).to eq(5)
    end
  end

  describe 'a flush that fails' do
    before { with_redis }

    it 'keeps the counts readable' do
      metrics = build_metrics
      redis.fail_writes = true
      3.times { record_sync(metrics, 'alpha') }

      expect(metrics.usage_count('alpha')).to eq(3)
    end

    it 'leaves the counts pending for the next attempt' do
      metrics = build_metrics
      redis.fail_writes = true
      3.times { record_sync(metrics, 'alpha') }
      metrics.force_flush_to_redis

      expect(metrics.instance_variable_get(:@pending_updates)['alpha']).to eq(3)
      expect(metrics.instance_variable_get(:@flushed_counts)['alpha']).to eq(0)
    end

    it 'does not double-count once Redis recovers' do
      metrics = build_metrics
      redis.fail_writes = true
      3.times { record_sync(metrics, 'alpha') }
      metrics.force_flush_to_redis

      redis.fail_writes = false
      metrics.force_flush_to_redis

      expect(redis.store['magick:stats:alpha']).to eq('3')
      expect(metrics.usage_count('alpha')).to eq(3)
    end

    it 'keeps the duration samples in memory' do
      metrics = build_metrics
      redis.fail_writes = true
      record_sync(metrics, 'alpha', 'enabled?', 2.0)
      record_sync(metrics, 'alpha', 'enabled?', 4.0)
      metrics.force_flush_to_redis

      expect(metrics.average_duration(feature_name: 'alpha')).to eq(3.0)
    end

    it 'credits only the features whose write landed' do
      metrics = build_metrics
      redis.fail_writes = ['magick:stats:beta']
      2.times { record_sync(metrics, 'alpha') }
      3.times { record_sync(metrics, 'beta') }
      metrics.force_flush_to_redis

      expect(redis.store['magick:stats:alpha']).to eq('2')
      expect(metrics.instance_variable_get(:@pending_updates)['beta']).to eq(3)
      expect(metrics.usage_count('alpha')).to eq(2)
      expect(metrics.usage_count('beta')).to eq(3)
    end
  end

  describe 'the duration sample buffer' do
    it 'stays capped' do
      metrics = build_metrics
      (described_class::METRICS_RING_CAP + 500).times { record_sync(metrics, 'alpha') }

      expect(metrics.instance_variable_get(:@metrics).length).to eq(described_class::METRICS_RING_CAP)
    end

    it 'evicts oldest-first so the average tracks recent behaviour' do
      metrics = build_metrics
      described_class::METRICS_RING_CAP.times { record_sync(metrics, 'alpha', 'enabled?', 100.0) }
      described_class::METRICS_RING_CAP.times { record_sync(metrics, 'alpha', 'enabled?', 1.0) }

      expect(metrics.average_duration(feature_name: 'alpha')).to eq(1.0)
    end
  end

  describe 'stats paths that enumerate Redis keys' do
    before { with_redis }

    it 'scans the keyspace for most_used_features instead of globbing it' do
      250.times { |i| redis.store["magick:stats:feature#{i}"] = (i + 1).to_s }
      metrics = build_metrics

      top = metrics.most_used_features(limit: 2)

      expect(top).to eq({ 'feature249' => 250, 'feature248' => 249 })
      expect(redis.scan_calls).to be > 1 # paged through the cursor
    end

    it 'scans when averaging every operation of one feature' do
      redis.store['magick:duration:sum:alpha:enabled?'] = '10.0'
      redis.store['magick:duration:count:alpha:enabled?'] = '5'
      redis.store['magick:duration:sum:alpha:value'] = '20.0'
      redis.store['magick:duration:count:alpha:value'] = '5'
      metrics = build_metrics

      expect(metrics.average_duration(feature_name: 'alpha')).to eq(3.0)
    end

    it 'scans when averaging across all features' do
      redis.store['magick:duration:sum:alpha:enabled?'] = '10.0'
      redis.store['magick:duration:count:alpha:enabled?'] = '5'
      redis.store['magick:duration:sum:beta:enabled?'] = '5.0'
      redis.store['magick:duration:count:beta:enabled?'] = '5'
      metrics = build_metrics

      expect(metrics.average_duration).to eq(1.5)
    end

    it 'reads a single feature and operation without enumerating keys at all' do
      redis.store['magick:duration:sum:alpha:enabled?'] = '10.0'
      redis.store['magick:duration:count:alpha:enabled?'] = '4'
      metrics = build_metrics

      expect(metrics.average_duration(feature_name: 'alpha', operation: 'enabled?')).to eq(2.5)
      expect(redis.scan_calls).to eq(0)
    end
  end

  describe 'reads of shared metrics state' do
    it 'waits for the writer to release the mutex before averaging' do
      metrics = build_metrics
      expect_blocked_on_mutex(metrics) { metrics.average_duration(feature_name: 'alpha') }
    end

    it 'waits for the writer to release the mutex before ranking features' do
      metrics = build_metrics
      expect_blocked_on_mutex(metrics) { metrics.most_used_features }
    end

    it 'waits for the writer to release the mutex before counting usage' do
      metrics = build_metrics
      expect_blocked_on_mutex(metrics) { metrics.usage_count('alpha') }
    end

    it 'survives concurrent recording' do
      metrics = build_metrics
      writer = Thread.new { 2_000.times { |i| record_sync(metrics, "feature#{i % 7}", 'enabled?', i.to_f) } }

      begin
        500.times do
          metrics.average_duration
          metrics.most_used_features
          metrics.usage_count('feature1')
        end
      ensure
        writer.join
      end

      expect(metrics.usage_count('feature1')).to be > 0
    end
  end

  # Holds the metrics mutex and asserts the read cannot complete until it is
  # released - i.e. the read is synchronized against the background writer.
  def expect_blocked_on_mutex(metrics)
    mutex = metrics.instance_variable_get(:@mutex)
    started = Queue.new
    reader = nil

    mutex.synchronize do
      reader = Thread.new do
        started << true
        yield
      end
      started.pop
      expect(reader.join(0.2)).to be_nil
    end

    expect(reader.join(5)).to be(reader)
  end
end
