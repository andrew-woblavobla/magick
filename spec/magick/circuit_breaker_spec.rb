# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::CircuitBreaker do
  let(:breaker) { described_class.new(failure_threshold: 3, timeout: 1) }

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

    it 'short-circuits while open: call returns false without invoking the block' do
      3.times { breaker.call { raise 'boom' } rescue nil }
      called = false
      result = breaker.call { called = true; :should_not_run }
      expect(result).to be false
      expect(called).to be false
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
  end
end
