# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Adapters::Registry, '#ensure_subscriber!' do
  let(:memory) { Magick::Adapters::Memory.new }
  let(:registry) { described_class.new(memory) }

  after { registry.shutdown }

  it 'is a no-op when the owning pid matches the current process' do
    # Inject a sentinel subscriber_thread so we can assert it was not replaced.
    sentinel = Thread.new { sleep }
    registry.instance_variable_set(:@subscriber_thread, sentinel)
    registry.instance_variable_set(:@owner_pid, Process.pid)

    registry.ensure_subscriber!

    expect(registry.instance_variable_get(:@subscriber_thread)).to equal(sentinel)
    sentinel.kill
  end

  it 'clears the inherited subscriber_thread when the owning pid differs from the current process' do
    inherited = Thread.new { sleep }
    registry.instance_variable_set(:@subscriber_thread, inherited)
    registry.instance_variable_set(:@owner_pid, Process.pid - 1)

    registry.ensure_subscriber!

    expect(registry.instance_variable_get(:@subscriber_thread)).not_to equal(inherited)
    expect(registry.instance_variable_get(:@owner_pid)).to eq(Process.pid)
    inherited.kill
  end

  it 'is safe to call when no redis adapter is configured (memory-only mode)' do
    expect { registry.ensure_subscriber! }.not_to raise_error
  end
end

RSpec.describe Magick::PerformanceMetrics, '#ensure_async_processor!' do
  let(:metrics) { described_class.new }

  after { metrics.stop_async_processor }

  it 'is a no-op when the owning pid matches the current process' do
    metrics.instance_variable_set(:@owner_pid, Process.pid)
    sentinel = metrics.instance_variable_get(:@async_thread)
    metrics.ensure_async_processor!
    expect(metrics.instance_variable_get(:@async_thread)).to equal(sentinel)
  end

  it 'restarts the async processor when the owning pid differs' do
    metrics.instance_variable_set(:@owner_pid, Process.pid - 1)
    metrics.ensure_async_processor!
    expect(metrics.instance_variable_get(:@owner_pid)).to eq(Process.pid)
  end
end
