# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::CircuitBreaker do
  let(:breaker) { described_class.new(failure_threshold: 3, timeout: 1) }

  # The timeout is compared against whole seconds, so `timeout: 0` needs the
  # clock's integer second to tick over exactly once. Cheaper than `timeout: 1`
  # for the examples that only care about what happens after the window.
  let(:fast_breaker) { described_class.new(failure_threshold: 3, timeout: 0) }
  let(:one_window) { 1.05 }

  describe 'state transitions' do
    it 'starts closed' do
      expect(breaker.state).to eq(:closed)
    end

    it 'stays closed below the failure threshold and keeps executing the block' do
      2.times do
        expect { breaker.call { raise 'boom' } }.to raise_error(RuntimeError)
      end
      expect(breaker.state).to eq(:closed)
      expect(breaker.call { :ok }).to eq(:ok)
    end

    it 'opens after reaching the failure threshold' do
      3.times do
        expect { breaker.call { raise 'boom' } }.to raise_error(RuntimeError)
      end
      expect(breaker.state).to eq(:open)
    end

    # An open breaker must be distinguishable from a backend that answered
    # `false`: the registry publishes cache invalidation only when the write
    # really landed, and it can only tell the two apart if this raises.
    it 'short-circuits while open: call raises CircuitOpenError without invoking the block' do
      3.times { breaker.call { raise 'boom' } rescue nil }
      called = false
      expect { breaker.call { called = true; :should_not_run } }
        .to raise_error(Magick::CircuitOpenError, /refusing to call the backend/)
      expect(called).to be false
    end

    it 'raises an AdapterError subclass, so existing adapter rescues stay fail-safe' do
      3.times { breaker.call { raise 'boom' } rescue nil }
      expect { breaker.call { :nope } }.to raise_error(Magick::AdapterError)
    end

    it 'transitions to half_open after the timeout window' do
      3.times { breaker.call { raise 'boom' } rescue nil }
      sleep 2.1
      expect(breaker.open?).to be false
      expect(breaker.state).to eq(:half_open)
    end

    it 'closes again after a successful call from half_open' do
      3.times { breaker.call { raise 'boom' } rescue nil }
      sleep 2.1
      breaker.call { :recovered }
      expect(breaker.state).to eq(:closed)
    end

    it 'resets failure_count on success' do
      2.times { breaker.call { raise 'boom' } rescue nil }
      breaker.call { :ok }
      expect(breaker.failure_count).to eq(0)
    end

    it 're-opens immediately when the single half_open probe fails' do
      3.times { fast_breaker.call { raise 'boom' } rescue nil }
      sleep one_window

      expect { fast_breaker.call { raise 'still down' } }.to raise_error(RuntimeError, 'still down')
      expect(fast_breaker.state).to eq(:open)
    end

    it 'admits exactly one probe per timeout window against a dead backend' do
      3.times { fast_breaker.call { raise 'boom' } rescue nil }
      sleep one_window

      attempts = 0
      5.times { fast_breaker.call { attempts += 1; raise 'still down' } rescue nil }
      expect(attempts).to eq(1)
    end

    it 'admits one probe per window, not one per request, over several windows' do
      3.times { fast_breaker.call { raise 'boom' } rescue nil }

      attempts = 0
      2.times do
        sleep one_window
        3.times { fast_breaker.call { attempts += 1; raise 'still down' } rescue nil }
      end
      expect(attempts).to eq(2)
    end
  end

  describe 'concurrency' do
    it 'does not double-count failures when many threads race on record_failure' do
      b = described_class.new(failure_threshold: 100, timeout: 60)
      threads = 20.times.map do
        Thread.new { 5.times { b.call { raise 'x' } rescue nil } }
      end
      threads.each(&:join)
      expect(b.failure_count).to eq(100)
    end

    it 'lets only one of many racing threads through the half_open probe' do
      b = described_class.new(failure_threshold: 1, timeout: 0)
      b.call { raise 'boom' } rescue nil
      sleep 1.1 # timeout is compared with > on whole seconds

      mutex = Mutex.new
      attempts = 0
      threads = 10.times.map do
        Thread.new do
          b.call do
            mutex.synchronize { attempts += 1 }
            sleep 0.05
            raise 'still down'
          end
        rescue StandardError
          nil
        end
      end
      threads.each(&:join)

      expect(attempts).to eq(1)
      expect(b.state).to eq(:open)
    end
  end
end
