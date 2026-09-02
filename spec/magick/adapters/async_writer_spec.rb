# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Adapters::AsyncWriter do
  subject(:writer) { described_class.new(**options) }

  let(:options) { {} }

  after { writer.shutdown(timeout: 2) }

  # Kernel#warn goes to $stderr; keep the suite output readable while still
  # letting examples assert on what was logged.
  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    yield
  end

  describe 'thread usage' do
    it 'starts no thread until the first write is submitted' do
      expect(writer.running?).to be false
    end

    it 'drains a burst of writes with a single worker thread' do
      done = Queue.new
      before_threads = Thread.list.size

      200.times { |i| writer.submit("burst-#{i}") { done << i } }
      peak = Thread.list.size - before_threads

      expect(peak).to eq(1)
      expect(wait_until { done.size == 200 }).to be true
    end
  end

  describe 'ordering' do
    it 'runs submitted jobs one at a time, in submission order' do
      order = []
      # A slow first job would overtake the rest under thread-per-write.
      writer.submit('a') do
        sleep 0.05
        order << 1
      end
      writer.submit('b') { order << 2 }
      writer.submit('c') { order << 3 }

      writer.shutdown(timeout: 2)

      expect(order).to eq([1, 2, 3])
    end

    it 'never runs two jobs concurrently' do
      concurrent = 0
      max_concurrent = 0
      mutex = Mutex.new

      50.times do
        writer.submit('overlap') do
          mutex.synchronize do
            concurrent += 1
            max_concurrent = [max_concurrent, concurrent].max
          end
          sleep 0.001
          mutex.synchronize { concurrent -= 1 }
        end
      end

      writer.shutdown(timeout: 2)

      expect(max_concurrent).to eq(1)
    end
  end

  describe 'bounded queue' do
    let(:options) { { queue_limit: 2, enqueue_timeout: 0.05 } }

    it 'exposes the configured bounds' do
      expect(writer.queue_limit).to eq(2)
      expect(writer.enqueue_timeout).to eq(0.05)
    end

    it 'falls back to defaults for nil or nonsense bounds' do
      defaulted = described_class.new(queue_limit: nil, enqueue_timeout: 0)
      expect(defaulted.queue_limit).to eq(described_class::DEFAULT_QUEUE_LIMIT)
      expect(defaulted.enqueue_timeout).to eq(described_class::DEFAULT_ENQUEUE_TIMEOUT)
      defaulted.shutdown(timeout: 1)
    end

    it 'never holds more than queue_limit pending writes' do
      release = Queue.new
      writer.submit('blocker') { release.pop }

      expect(wait_until { writer.running? }).to be true
      capture_stderr do
        6.times { |i| writer.submit("overflow-#{i}") { nil } }
      end

      expect(writer.pending).to be <= 2

      release << :go
    end

    it 'blocks the caller while the queue is full instead of growing' do
      release = Queue.new
      writer.submit('blocker') { release.pop }
      writer.submit('queued-1') { nil }
      writer.submit('queued-2') { nil }

      # Queue is full; this caller must wait for the drain rather than being
      # accepted immediately.
      accepted = nil
      elapsed = nil
      caller_thread = Thread.new do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        accepted = writer.submit('backpressured') { nil }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      sleep 0.02
      expect(caller_thread.alive?).to be true # still blocked on a full queue

      release << :go # drains the blocker, freeing a slot
      caller_thread.join(2)

      expect(accepted).to eq(:queued)
      expect(elapsed).to be > 0.01
    end

    it 'drops the write with a warning once the enqueue timeout expires' do
      release = Queue.new
      writer.submit('blocker') { release.pop }
      expect(wait_until { writer.running? }).to be true

      ran = []
      writer.submit('queued-1') { ran << 'queued-1' }
      writer.submit('queued-2') { ran << 'queued-2' }

      result = nil
      logged = capture_stderr { result = writer.submit('dropped-me') { ran << 'dropped-me' } }

      expect(result).to eq(:dropped)
      expect(logged).to include('async write queue full', 'dropped-me', 'limit 2')
      expect(writer.stats[:dropped]).to eq(1)

      release << :go
      writer.shutdown(timeout: 2)
      expect(ran).not_to include('dropped-me')
    end

    it 'rate-limits the drop warning but counts every drop' do
      release = Queue.new
      writer.submit('blocker') { release.pop }
      expect(wait_until { writer.running? }).to be true
      writer.submit('queued-1') { nil }
      writer.submit('queued-2') { nil }

      logged = capture_stderr do
        3.times { |i| writer.submit("dropped-#{i}") { nil } }
      end

      expect(logged.lines.size).to eq(1)
      expect(writer.stats[:dropped]).to eq(3)

      release << :go
    end
  end

  describe 'failure handling' do
    it 'keeps draining after a job raises' do
      ran = []

      capture_stderr do
        writer.submit('boom') { raise 'redis exploded' }
        writer.submit('after') { ran << :after }
        writer.shutdown(timeout: 2)
      end

      expect(ran).to eq([:after])
      expect(writer.stats).to include(failed: 1, completed: 1)
    end

    it 'logs the failing write with its label and the error' do
      logged = capture_stderr do
        writer.submit('checkout_v2') { raise ArgumentError, 'redis exploded' }
        writer.shutdown(timeout: 2)
      end

      expect(logged).to include('async write failed', 'checkout_v2', 'ArgumentError', 'redis exploded')
    end

    it 'sanitizes control characters out of the log line' do
      logged = capture_stderr do
        writer.submit("evil\nINJECTED") { raise 'nope' }
        writer.shutdown(timeout: 2)
      end

      expect(logged.lines.size).to eq(1)
      expect(logged).to include('evil INJECTED')
    end

    it 'requires a block' do
      expect { writer.submit('no-block') }.to raise_error(ArgumentError)
    end
  end

  describe '#shutdown' do
    it 'drains everything already queued' do
      ran = []
      20.times { |i| writer.submit("job-#{i}") { ran << i } }

      stats = writer.shutdown(timeout: 5)

      expect(ran.size).to eq(20)
      expect(stats[:abandoned]).to eq(0)
      expect(writer.pending).to eq(0)
      expect(writer.running?).to be false
    end

    it 'abandons the backlog deterministically when the drain times out' do
      stuck = Queue.new # never released
      writer.submit('stuck') { stuck.pop }
      expect(wait_until { writer.running? }).to be true
      4.times { |i| writer.submit("never-#{i}") { raise 'must not run' } }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stats = capture_stderr_and_return { writer.shutdown(timeout: 0.2) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 2 # no hang: bounded by the drain timeout
      expect(stats[:abandoned]).to eq(4)
      expect(writer.running?).to be false
      expect(writer.pending).to eq(0)
    end

    it 'is idempotent' do
      writer.submit('job') { nil }
      expect { 3.times { writer.shutdown(timeout: 1) } }.not_to raise_error
    end

    it 'rejects later submissions so the caller can write inline' do
      writer.shutdown(timeout: 1)
      ran = false

      expect(writer.submit('after-shutdown') { ran = true }).to eq(:rejected)
      expect(ran).to be false
      expect(writer.stopped?).to be true
    end

    it 'hands a blocked caller back its write instead of stranding it' do
      bounded = described_class.new(queue_limit: 1, enqueue_timeout: 10)
      release = Queue.new
      bounded.submit('blocker') { release.pop }
      expect(wait_until { bounded.running? }).to be true
      bounded.submit('fills-the-queue') { nil }

      result = nil
      caller_thread = Thread.new { result = bounded.submit('blocked') { nil } }
      sleep 0.05
      expect(caller_thread.alive?).to be true

      bounded.shutdown(timeout: 0.2)
      caller_thread.join(2)

      expect(result).to eq(:rejected)
      release << :go
    end
  end

  describe 'fork safety' do
    it 'starts a fresh worker and queue when the owning pid changes' do
      writer.submit('parent-write') { nil }
      writer.shutdown(timeout: 1)

      # Simulate the child side of a fork: inherited state, no live thread.
      writer.instance_variable_set(:@owner_pid, Process.pid - 1)
      writer.instance_variable_set(:@queue, [['stale', -> { raise 'parent write must not replay' }]])

      ran = Queue.new
      expect(writer.submit('child-write') { ran << :child }).to eq(:queued)

      expect(wait_until { !ran.empty? }).to be true
      expect(writer.running?).to be true
    end
  end

  # shutdown returns stats; wrap it so warnings do not leak into spec output.
  def capture_stderr_and_return
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end
end
