# frozen_string_literal: true

require 'spec_helper'

# A process that cannot subscribe to the invalidation channel serves stale
# flags until the periodic refresh catches them — and until now nothing said so
# outside development. These specs drive the subscriber thread against a
# scripted stand-in for the redis-rb client, so a failing SUBSCRIBE, a dropped
# connection and a recovery can each be produced on demand.
module SubscriberHealthSpec
  # What the registry sees as its Redis adapter: the subscriber thread only
  # ever asks it for #client.
  class FakeRedisAdapter
    attr_reader :client

    def initialize(client)
      @client = client
    end
  end

  # The redis-rb client. The registry dup's it and subscribes on the copy; the
  # copy is this same object, so the spec can watch the attempts.
  class ScriptedClient
    Callbacks = Struct.new(:on_subscribe, :on_unsubscribe, :on_message) do
      def subscribe(&block)
        self.on_subscribe = block
      end

      def unsubscribe(&block)
        self.on_unsubscribe = block
      end

      def message(&block)
        self.on_message = block
      end
    end

    NOPERM = 'NOPERM this user has no permissions to run the subscribe command'

    attr_reader :attempts

    # One symbol per subscribe attempt: :fail raises, :connect acknowledges the
    # subscription and blocks until it is dropped or unsubscribed. Attempts past
    # the end of the script connect.
    def initialize(*script)
      @script = script
      @attempts = 0
      @stop = Queue.new
      @connected = Queue.new
    end

    # Every attempt fails.
    def self.failing
      new(:fail).tap { |client| client.instance_variable_set(:@always_fail, true) }
    end

    def dup
      self
    end

    def subscribe(_channel)
      @attempts += 1
      step = @always_fail ? :fail : (@script.shift || :connect)
      raise StandardError, NOPERM if step == :fail

      callbacks = Callbacks.new
      yield callbacks
      callbacks.on_subscribe&.call('magick:cache:invalidate', 1)
      @connected << true
      @stop.pop
      callbacks.on_unsubscribe&.call('magick:cache:invalidate', 0)
    end

    # Blocks until the subscriber thread has a live subscription.
    def wait_connected(timeout: 2)
      @connected.pop(timeout: timeout) or raise 'subscriber never connected'
    end

    # The server closed the connection: `subscribe` returns without an error.
    def drop_connection
      @stop << :dropped
    end

    def unsubscribe(*)
      @stop << :unsubscribed
    end

    def close
      @stop << :closed
    end
  end
end

RSpec.describe Magick::Adapters::Registry, 'subscriber health' do
  let(:memory) { Magick::Adapters::Memory.new }

  before do
    stub_const('Magick::Adapters::Registry::SUBSCRIBER_RETRY_DELAY', 0.01)
    allow(Magick::AdapterFailure).to receive(:report)
    allow(Magick::AdapterFailure).to receive(:report_recovery)
  end

  def start(client)
    described_class.new(memory, SubscriberHealthSpec::FakeRedisAdapter.new(client))
  end

  def wait_until(timeout: 2.0)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
  end

  it 'is listening once Redis acknowledges the subscription, and not after shutdown' do
    client = SubscriberHealthSpec::ScriptedClient.new
    registry = start(client)
    client.wait_connected

    expect(registry.subscriber_running?).to be true
    expect(registry.health).to include(subscriber_running: true, subscriber_last_error: nil)

    registry.shutdown(timeout: 1)

    expect(registry.subscriber_running?).to be false
  end

  it 'reports a subscription that keeps failing once, not on every retry, and says why in health' do
    client = SubscriberHealthSpec::ScriptedClient.failing
    registry = start(client)
    begin
      wait_until { client.attempts >= 5 }

      expect(client.attempts).to be >= 5
      expect(registry.subscriber_running?).to be false
      expect(registry.health[:subscriber_last_error]).to include('NOPERM')
      expect(Magick::AdapterFailure).to have_received(:report)
        .with(backend: :redis, operation: :subscribe, error: an_instance_of(StandardError)).once
    ensure
      registry.shutdown(timeout: 1)
    end
  end

  it 'reports again once the report interval has passed' do
    stub_const('Magick::Adapters::Registry::SUBSCRIBER_FAILURE_REPORT_INTERVAL', 0.05)
    client = SubscriberHealthSpec::ScriptedClient.failing
    registry = start(client)
    begin
      wait_until { client.attempts >= 12 }

      expect(Magick::AdapterFailure).to have_received(:report)
        .with(hash_including(backend: :redis, operation: :subscribe)).at_least(:twice)
    ensure
      registry.shutdown(timeout: 1)
    end
  end

  it 'logs the recovery when the subscription is re-established, and clears the error' do
    client = SubscriberHealthSpec::ScriptedClient.new(:fail, :fail)
    registry = start(client)
    begin
      client.wait_connected
      wait_until { registry.subscriber_running? }

      expect(client.attempts).to eq(3)
      expect(registry.subscriber_running?).to be true
      expect(registry.health[:subscriber_last_error]).to be_nil
      expect(Magick::AdapterFailure).to have_received(:report).once
      expect(Magick::AdapterFailure).to have_received(:report_recovery)
        .with(backend: :redis, operation: :subscribe).once
    ensure
      registry.shutdown(timeout: 1)
    end
  end

  it 'resubscribes when the connection goes away without a shutdown' do
    client = SubscriberHealthSpec::ScriptedClient.new
    registry = start(client)
    begin
      client.wait_connected
      client.drop_connection
      client.wait_connected
      wait_until { registry.subscriber_running? }

      expect(client.attempts).to eq(2)
      expect(registry.subscriber_running?).to be true
      expect(Magick::AdapterFailure).to have_received(:report)
        .with(backend: :redis, operation: :subscribe, error: an_instance_of(Magick::AdapterError)).once
    ensure
      registry.shutdown(timeout: 1)
    end
  end

  it 'does not report the subscription ending during shutdown' do
    client = SubscriberHealthSpec::ScriptedClient.new
    registry = start(client)
    client.wait_connected

    registry.shutdown(timeout: 1)

    expect(Magick::AdapterFailure).not_to have_received(:report)
  end
end
