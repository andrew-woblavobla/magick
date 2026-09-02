# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::AdapterFailure do
  let(:logger) { FakeRails::Logger.new }
  let(:event_reporter) { FakeRails::EventReporter.new }
  let(:error) { Magick::AdapterError.new('Failed to set in Redis: Connection refused') }

  def with_rails(&block)
    stub_const('Rails', FakeRails.build(logger: logger, event: event_reporter))
    FakeRails.with_event_channel(&block)
  end

  describe '.report' do
    it 'logs at error severity, not debug or warn' do
      with_rails do
        described_class.report(backend: :redis, operation: :set, feature_name: 'checkout', error: error)
      end

      expect(logger.errors.size).to eq(1)
      expect(logger.warnings).to be_empty
      expect(logger.infos).to be_empty
    end

    it 'names the backend, the operation, the feature and the cause' do
      with_rails do
        described_class.report(backend: :active_record, operation: :set_all_data, feature_name: 'checkout',
                               error: error)
      end

      expect(logger.errors.first).to eq(
        "Magick: active_record set_all_data failed for 'checkout': " \
        'Magick::AdapterError: Failed to set in Redis: Connection refused'
      )
    end

    it 'emits an event on the structured event channel' do
      with_rails do
        described_class.report(backend: :redis, operation: :set, feature_name: 'checkout', error: error)
      end

      event = event_reporter.events.first
      expect(event[:name]).to eq('magick.feature_flag.adapter_write_failed')
      expect(event[:payload]).to include(
        feature_name: 'checkout',
        backend: 'redis',
        operation: 'set',
        error_class: 'Magick::AdapterError',
        error_message: 'Failed to set in Redis: Connection refused'
      )
    end

    it 'reports a dropped write that had no exception, using the given reason' do
      with_rails do
        described_class.report(backend: :redis, operation: :set, feature_name: 'checkout',
                               reason: 'circuit breaker open')
      end

      expect(logger.errors.first).to eq("Magick: redis set failed for 'checkout': circuit breaker open")
      expect(event_reporter.events.first[:payload]).to include(reason: 'circuit breaker open', error_class: nil)
    end

    # Log injection: a feature name or driver message arriving off the wire must
    # not be able to forge extra log lines.
    it 'sanitizes the feature name and the error message' do
      with_rails do
        described_class.report(backend: :redis, operation: :set,
                               feature_name: "checkout\nFATAL: forged line",
                               error: Magick::AdapterError.new("boom\r\nINFO: forged"))
      end

      expect(logger.errors.first).not_to include("\n")
      expect(logger.errors.first).to include('checkout FATAL: forged line')
      expect(event_reporter.events.first[:payload][:error_message]).to eq('boom  INFO: forged')
    end

    it 'truncates a flooding error message to the shared LogSafe limit' do
      with_rails do
        described_class.report(backend: :redis, operation: :set, feature_name: 'checkout',
                               error: Magick::AdapterError.new('x' * 5000))
      end

      expect(event_reporter.events.first[:payload][:error_message].length).to eq(Magick::LogSafe::MAX_LEN)
    end

    it 'falls back to $stderr when the host has no Rails logger' do
      # Explicitly, not by assuming the suite is Rails-free: spec/rails_helper.rb
      # boots a real application, and once any spec file has required it `Rails`
      # is defined for every example in the process.
      hide_const('Rails')

      expect do
        described_class.report(backend: :redis, operation: :set, feature_name: 'checkout', error: error)
      end.to output(/Magick: redis set failed for 'checkout'/).to_stderr
    end

    it 'returns nil rather than raising when the logger itself blows up' do
      exploding_logger = Class.new do
        def error(*) = raise(IOError, 'log pipe closed')
      end.new
      stub_const('Rails', FakeRails.build(logger: exploding_logger, event: event_reporter))

      result = nil
      expect do
        FakeRails.with_event_channel do
          result = described_class.report(backend: :redis, operation: :set, feature_name: 'checkout', error: error)
        end
      end.not_to raise_error
      expect(result).to be_nil
    end

    it 'still logs when the event channel raises' do
      exploding_reporter = Class.new do
        def notify(*) = raise('event pipeline down')
      end.new
      stub_const('Rails', FakeRails.build(logger: logger, event: exploding_reporter))

      expect do
        FakeRails.with_event_channel do
          described_class.report(backend: :redis, operation: :set, feature_name: 'checkout', error: error)
        end
      end.not_to raise_error
      expect(logger.errors.size).to eq(1)
    end
  end
end
