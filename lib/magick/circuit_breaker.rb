# frozen_string_literal: true

module Magick
  # Trips after `failure_threshold` consecutive-ish failures and then refuses
  # to run the block for `timeout` seconds, so a dead backend costs one failed
  # call per window instead of one per request.
  #
  # Two properties the callers depend on:
  #
  # * An open circuit RAISES CircuitOpenError rather than returning a falsey
  #   value. A breaker that answers `false` is indistinguishable from a backend
  #   that legitimately stored `false`, and the registry's write path would go
  #   on to publish a cache invalidation for a write that never happened —
  #   telling every peer to reload the pre-toggle value.
  # * Half-open admits exactly ONE probe, and a probe that fails re-opens the
  #   circuit immediately. Resetting the failure count on the way into half-open
  #   would mean a permanently dead backend absorbs `failure_threshold`
  #   requests per timeout window rather than one.
  class CircuitBreaker
    DEFAULT_FAILURE_THRESHOLD = 5
    DEFAULT_TIMEOUT = 60

    attr_reader :failure_count, :last_failure_time

    def initialize(failure_threshold: DEFAULT_FAILURE_THRESHOLD, timeout: DEFAULT_TIMEOUT)
      @failure_threshold = failure_threshold
      @timeout = timeout
      @failure_count = 0
      @last_failure_time = nil
      @state = :closed
      @half_open_probe = false
      @mutex = Mutex.new
    end

    # Runs the block, or raises CircuitOpenError without touching it.
    def call
      raise CircuitOpenError, "Circuit is #{state}; refusing to call the backend" unless acquire

      begin
        result = yield
        record_success
        result
      rescue StandardError => e
        record_failure
        raise e
      end
    end

    def state
      @mutex.synchronize { current_state }
    end

    def open?
      @mutex.synchronize { current_state == :open }
    end

    private

    # Lazily promote :open -> :half_open once the timeout window has elapsed.
    # Caller must hold @mutex.
    def current_state
      if @state == :open && (Time.now.to_i - @last_failure_time.to_i) > @timeout
        @state = :half_open
        @half_open_probe = false
      end
      @state
    end

    # Claim the right to run the block. A closed circuit always admits; a
    # half-open circuit admits a single probe and blocks every concurrent
    # caller behind it; an open circuit admits nothing.
    def acquire
      @mutex.synchronize do
        case current_state
        when :closed
          true
        when :half_open
          if @half_open_probe
            false
          else
            @half_open_probe = true
          end
        else
          false
        end
      end
    end

    def record_success
      @mutex.synchronize do
        @failure_count = 0
        @half_open_probe = false
        @state = :closed
      end
    end

    def record_failure
      @mutex.synchronize do
        @failure_count += 1
        @last_failure_time = Time.now
        # A failed half-open probe re-opens straight away: the backend is
        # demonstrably still down, so there is nothing to be gained by letting
        # the count climb back to the threshold first.
        @state = :open if @state == :half_open || @failure_count >= @failure_threshold
        @half_open_probe = false
      end
    end
  end
end
