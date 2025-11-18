# frozen_string_literal: true

module Magick
  class CircuitBreaker
    DEFAULT_FAILURE_THRESHOLD = 5
    DEFAULT_TIMEOUT = 60

    attr_reader :failure_count, :last_failure_time, :state

    def initialize(failure_threshold: DEFAULT_FAILURE_THRESHOLD, timeout: DEFAULT_TIMEOUT)
      @failure_threshold = failure_threshold
      @timeout = timeout
      @failure_count = 0
      @last_failure_time = nil
      @state = :closed
      @mutex = Mutex.new
    end

    def call
      return false if open?

      begin
        result = yield
        record_success
        result
      rescue StandardError => e
        record_failure
        raise e
      end
    end

    def open?
      @mutex.synchronize do
        if @state == :open
          if Time.now.to_i - @last_failure_time.to_i > @timeout
            @state = :half_open
            @failure_count = 0
            false
          else
            true
          end
        else
          false
        end
      end
    end

    private

    def record_success
      @mutex.synchronize do
        @failure_count = 0
        @state = :closed if @state == :half_open
      end
    end

    def record_failure
      @mutex.synchronize do
        @failure_count += 1
        @last_failure_time = Time.now
        @state = :open if @failure_count >= @failure_threshold
      end
    end
  end
end
