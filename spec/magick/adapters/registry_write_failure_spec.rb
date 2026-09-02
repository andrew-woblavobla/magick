# frozen_string_literal: true

require 'spec_helper'

# The registry writes memory first and never rolls it back, so a failed Redis or
# ActiveRecord write leaves this process serving a value no other process has.
# Every one of those failures has to be visible — in every environment, at error
# severity, and on the event channel — without ever reaching the caller.
RSpec.describe Magick::Adapters::Registry do
  let(:logger) { FakeRails::Logger.new }
  let(:event_reporter) { FakeRails::EventReporter.new }
  let(:memory_adapter) { Magick::Adapters::Memory.new }

  # A backend that fails every write the way the real adapters do: reads still
  # work, writes raise Magick::AdapterError.
  def failing_backend(message)
    Class.new(Magick::Adapters::Memory) do
      define_method(:failure) { Magick::AdapterError.new(message) }
      def set(*) = raise(failure)
      def set_all_data(*) = raise(failure)
      def delete(*) = raise(failure)
      def client = nil
    end.new
  end

  let(:failing_redis) { failing_backend('Failed to set in Redis: Connection refused') }
  let(:failing_active_record) { failing_backend('Failed to set in ActiveRecord: could not connect') }

  # Rails is stubbed before the registry is built (the test environment skips the
  # Pub/Sub subscriber thread), and the structured event channel is only loaded
  # for the write itself.
  def build_registry(redis: nil, **kwargs)
    stub_const('Rails', FakeRails.build(logger: logger, event: event_reporter, env: 'test'))
    described_class.new(memory_adapter, redis, **kwargs)
  end

  def write(registry, &block)
    FakeRails.with_event_channel { block.call(registry) }
  end

  def events
    event_reporter.events.select { |e| e[:name] == 'magick.feature_flag.adapter_write_failed' }
  end

  describe 'a failed Redis write' do
    let(:registry) { build_registry(redis: failing_redis) }

    it 'logs at error severity' do
      write(registry) { |r| r.set(:checkout, 'value', true) }

      expect(logger.errors).to include(
        "Magick: redis set failed for 'checkout': Magick::AdapterError: Failed to set in Redis: Connection refused"
      )
    end

    it 'emits an adapter_write_failed event naming the backend and operation' do
      write(registry) { |r| r.set(:checkout, 'value', true) }

      expect(events.first[:payload]).to include(
        feature_name: 'checkout',
        backend: 'redis',
        operation: 'set',
        error_class: 'Magick::AdapterError'
      )
    end

    it 'does not raise into the caller' do
      expect { write(registry) { |r| r.set(:checkout, 'value', true) } }.not_to raise_error
    end

    it 'keeps the memory write that the failure left diverged' do
      write(registry) { |r| r.set(:checkout, 'value', true) }

      expect(memory_adapter.get(:checkout, 'value')).to be true
    end

    it 'reports a failed bulk write' do
      write(registry) { |r| r.set_all_data(:checkout, { 'value' => true }) }

      expect(events.map { |e| e[:payload][:operation] }).to include('set_all_data')
      expect(logger.errors.first).to include('redis set_all_data failed')
    end

    it 'reports a failed delete' do
      write(registry) { |r| r.delete(:checkout) }

      expect(events.first[:payload]).to include(backend: 'redis', operation: 'delete')
      expect(logger.errors.first).to include('redis delete failed')
    end

    it 'contains a driver error that is not wrapped in AdapterError' do
      raw = Class.new(Magick::Adapters::Memory) do
        def set(*) = raise(IOError, 'closed stream')
      end.new
      registry = build_registry(redis: raw)

      expect { write(registry) { |r| r.set(:checkout, 'value', true) } }.not_to raise_error
      expect(events.first[:payload]).to include(error_class: 'IOError', error_message: 'closed stream')
    end
  end

  describe 'a failed ActiveRecord write' do
    let(:registry) { build_registry(active_record_adapter: failing_active_record) }

    it 'logs at error severity and emits an event' do
      write(registry) { |r| r.set(:checkout, 'value', true) }

      expect(logger.errors.first).to include('active_record set failed')
      expect(events.first[:payload]).to include(backend: 'active_record', operation: 'set')
    end

    it 'does not raise into the caller' do
      expect { write(registry) { |r| r.set(:checkout, 'value', true) } }.not_to raise_error
    end

    it 'reports a failed bulk write' do
      write(registry) { |r| r.set_all_data(:checkout, { 'value' => true }) }

      expect(events.first[:payload]).to include(backend: 'active_record', operation: 'set_all_data')
    end

    it 'reports a failed delete' do
      write(registry) { |r| r.delete(:checkout) }

      expect(events.first[:payload]).to include(backend: 'active_record', operation: 'delete')
    end
  end

  # The scenario the ticket describes: a backend that stays down. Once the
  # breaker trips, the adapter is never called again, so the drop has to be
  # reported on its own or the divergence goes quiet exactly when it is growing.
  describe 'a write dropped by an open circuit breaker' do
    let(:breaker) { Magick::CircuitBreaker.new(failure_threshold: 1) }
    let(:registry) { build_registry(redis: failing_redis, circuit_breaker: breaker) }

    it 'keeps reporting after the breaker has tripped' do
      write(registry) do |r|
        r.set(:checkout, 'value', true)   # trips the breaker
        r.set(:checkout, 'value', false)  # dropped without touching Redis
      end

      expect(breaker.state).to eq(:open)
      expect(events.size).to eq(2)
      expect(events.last[:payload]).to include(backend: 'redis', operation: 'set', reason: 'circuit breaker open')
      expect(logger.errors.last).to eq("Magick: redis set failed for 'checkout': circuit breaker open")
    end
  end

  describe 'a failed cache invalidation publish' do
    # Writes succeed; only the Pub/Sub publish blows up, which leaves every
    # other process holding a stale value.
    let(:unpublishable_redis) do
      Class.new(Magick::Adapters::Memory) do
        def client
          Class.new do
            def publish(*) = raise(IOError, 'connection reset')
          end.new
        end
      end.new
    end

    it 'is reported instead of silently dropped' do
      registry = build_registry(redis: unpublishable_redis)

      write(registry) { |r| r.set(:checkout, 'value', true) }

      expect(events.first[:payload]).to include(backend: 'redis', operation: 'publish_cache_invalidation')
      expect(logger.errors.first).to include('redis publish_cache_invalidation failed')
    end
  end

  describe 'an async write' do
    let(:registry) { build_registry(redis: failing_redis, async: true) }

    it 'reports the failure from the background thread' do
      write(registry) do |r|
        r.set(:checkout, 'value', true)
        # The write is fire-and-forget; wait for the thread that carries it.
        Thread.list.each { |t| t.join(2) if t.name.to_s.start_with?('magick-async-write') }
      end

      expect(events.first[:payload]).to include(backend: 'redis', operation: 'set')
      expect(logger.errors.first).to include('redis set failed')
    end
  end
end
