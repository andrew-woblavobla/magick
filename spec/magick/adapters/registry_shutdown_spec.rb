# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Adapters::Registry, '#shutdown' do
  let(:memory_adapter) { Magick::Adapters::Memory.new }

  it 'is a no-op when no subscriber thread was started' do
    registry = described_class.new(memory_adapter)
    expect { registry.shutdown }.not_to raise_error
    expect(registry.instance_variable_get(:@stopping)).to be true
  end

  it 'signals the retry loop via a stopping flag' do
    registry = described_class.new(memory_adapter)
    registry.shutdown
    expect(registry.stopping?).to be true
  end

  it 'terminates a live subscriber thread via unsubscribe/close within the timeout' do
    registry = described_class.new(memory_adapter)
    latch = Queue.new

    thread = Thread.new do
      latch.pop # block until unsubscribe is called
    rescue ClosedQueueError
      # simulates connection closed during shutdown
    end

    fake_subscriber = instance_double('FakeRedisConnection')
    allow(fake_subscriber).to receive(:unsubscribe) { latch.close }
    allow(fake_subscriber).to receive(:close)

    registry.instance_variable_set(:@subscriber_thread, thread)
    registry.instance_variable_set(:@subscriber, fake_subscriber)

    registry.shutdown(timeout: 2)

    expect(thread.alive?).to be false
    expect(fake_subscriber).to have_received(:unsubscribe)
    expect(fake_subscriber).to have_received(:close)
  end

  it 'force-kills the subscriber thread if it refuses to exit within the timeout' do
    registry = described_class.new(memory_adapter)

    thread = Thread.new { sleep }

    uncooperative_subscriber = instance_double('FakeRedisConnection')
    allow(uncooperative_subscriber).to receive(:unsubscribe) # does not stop thread
    allow(uncooperative_subscriber).to receive(:close)

    registry.instance_variable_set(:@subscriber_thread, thread)
    registry.instance_variable_set(:@subscriber, uncooperative_subscriber)

    registry.shutdown(timeout: 0.2)

    expect(thread.alive?).to be false
  end

  it 'is idempotent across multiple calls' do
    registry = described_class.new(memory_adapter)
    expect { 3.times { registry.shutdown } }.not_to raise_error
  end

  it 'swallows errors raised by the subscriber connection' do
    registry = described_class.new(memory_adapter)

    angry_subscriber = instance_double('FakeRedisConnection')
    allow(angry_subscriber).to receive(:unsubscribe).and_raise(StandardError, 'connection gone')
    allow(angry_subscriber).to receive(:close).and_raise(StandardError, 'boom')

    thread = Thread.new { sleep }
    registry.instance_variable_set(:@subscriber_thread, thread)
    registry.instance_variable_set(:@subscriber, angry_subscriber)

    expect { registry.shutdown(timeout: 0.2) }.not_to raise_error
    expect(thread.alive?).to be false
  end
end

RSpec.describe 'Magick.shutdown!' do
  it 'stops the adapter registry subscriber' do
    memory_adapter = Magick::Adapters::Memory.new
    registry = Magick::Adapters::Registry.new(memory_adapter)
    Magick.adapter_registry = registry

    expect(registry).to receive(:shutdown)
    Magick.shutdown!
  end

  it 'stops the performance metrics async processor' do
    metrics = Magick::PerformanceMetrics.new
    Magick.performance_metrics = metrics

    expect(metrics).to receive(:stop_async_processor)
    Magick.shutdown!
  end

  it 'is safe to call when nothing has been configured' do
    Magick.adapter_registry = nil
    Magick.performance_metrics = nil
    expect { Magick.shutdown! }.not_to raise_error
  end
end
