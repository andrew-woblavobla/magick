# frozen_string_literal: true

module Magick
  module Adapters
    # Serialized, bounded drain for asynchronous adapter writes.
    #
    # With `async_updates enabled: true` the registry used to spawn one thread
    # per write. That had two failure modes:
    #
    #   1. **No ordering.** Two writes to the same feature raced each other, so
    #      Redis could keep the OLDER value while memory kept the newer one —
    #      a permanent divergence, made worse by the trailing Pub/Sub publish
    #      telling every other process to load the stale value.
    #   2. **No cap.** An Admin UI bulk toggle or a boot-time DSL apply spawned
    #      one thread (and one Redis connection) per write, which can exhaust
    #      the Redis connection pool.
    #
    # This class fixes both: exactly ONE worker thread drains a bounded FIFO
    # queue, so writes reach Redis in the order they were submitted and a burst
    # of N writes costs one thread and one connection regardless of N.
    #
    # ## Backpressure policy: block, then drop with a log line
    #
    # When the queue is full, `#submit` BLOCKS the caller for up to
    # `enqueue_timeout` seconds (backpressure — the queue drains while the
    # caller waits). If it is still full when that expires, the write is
    # DROPPED and a warning is emitted with the running drop total.
    #
    # Dropping is deliberate. The alternatives are worse for a feature-flag
    # library whose contract is "never take the host application down":
    #
    #   * Blocking forever turns a wedged Redis into an application-wide stall.
    #   * Running the write inline on the caller's thread would let it overtake
    #     the writes already queued for the same feature — reintroducing exactly
    #     the out-of-order divergence this class exists to prevent.
    #
    # A full queue means ~`queue_limit` writes are already backed up, i.e. Redis
    # is down or unreachably slow; in that state the write would most likely
    # have failed anyway, memory (the read path) still holds the correct value,
    # and the drop is loud rather than silent.
    class AsyncWriter
      # Pending writes held before backpressure kicks in.
      DEFAULT_QUEUE_LIMIT = 1_000

      # How long `#submit` blocks on a full queue before dropping the write.
      DEFAULT_ENQUEUE_TIMEOUT = 5.0

      # How long `#shutdown` lets the worker drain before abandoning the rest.
      DEFAULT_DRAIN_TIMEOUT = 5

      # Cap on how often a drop is logged, so a sustained outage cannot flood
      # the log pipeline. The cumulative count is included in every line.
      DROP_WARN_INTERVAL = 1.0

      # Bounded wait in the worker's idle loop. Work is signalled explicitly;
      # the timeout only guarantees the worker re-checks its stop flag even if
      # a signal is ever missed.
      IDLE_WAIT = 1.0

      attr_reader :queue_limit, :enqueue_timeout

      # `on_drop` is called as `(label, total_dropped)` when a write is dropped,
      # rate-limited by DROP_WARN_INTERVAL. The host passes one so the drop goes
      # through its own failed-write reporting (a dropped write is a write that
      # never landed); without one the writer warns on $stderr by itself.
      def initialize(queue_limit: nil, enqueue_timeout: nil, name: 'magick-async-writer', on_drop: nil)
        @queue_limit = positive_integer(queue_limit, DEFAULT_QUEUE_LIMIT)
        @enqueue_timeout = positive_float(enqueue_timeout, DEFAULT_ENQUEUE_TIMEOUT)
        @name = name
        @on_drop = on_drop

        @mutex = Mutex.new
        @work_available = ConditionVariable.new
        @space_available = ConditionVariable.new

        @queue = []
        @thread = nil
        @owner_pid = Process.pid
        @stopped = false

        @completed = 0
        @failed = 0
        @dropped = 0
        @last_drop_warn_at = nil
      end

      # Hand a write to the worker thread. Returns:
      #
      #   :queued   — accepted; the worker will run it in submission order.
      #   :dropped  — queue stayed full for `enqueue_timeout`; not run (logged).
      #   :rejected — the writer is shut down; the caller must run it inline.
      #
      # The worker thread is started on first submit (and restarted after a
      # fork, or if a job killed it), so an idle registry costs no threads.
      def submit(label = nil, &job)
        raise ArgumentError, 'AsyncWriter#submit requires a block' unless job

        @mutex.synchronize do
          reset_after_fork
          return :rejected if @stopped

          start_worker
          admission = wait_for_space(label)
          return admission unless admission == :queued

          @queue << [label, job]
          @work_available.signal
          :queued
        end
      end

      # Stop accepting work, drain what is already queued, and make sure no
      # worker thread outlives this call.
      #
      # Deterministic by construction: the worker gets `timeout` seconds to
      # finish the backlog; anything still queued when that expires is
      # abandoned (and reported), the thread is killed, and the queue is
      # cleared. Producers blocked on a full queue are woken with `:rejected`
      # rather than left waiting. Idempotent.
      #
      # Returns a stats hash including `:abandoned`.
      def shutdown(timeout: DEFAULT_DRAIN_TIMEOUT)
        thread = @mutex.synchronize do
          @stopped = true
          @work_available.broadcast
          @space_available.broadcast
          @thread
        end

        if thread && thread != Thread.current && !join_quietly(thread, timeout)
          thread.kill
          join_quietly(thread, 1)
        end

        @mutex.synchronize do
          abandoned = @queue.size
          @queue.clear
          @thread = nil
          stats_snapshot(abandoned: abandoned)
        end
      end

      # Number of writes accepted but not yet sent to Redis.
      def pending
        @mutex.synchronize { @queue.size }
      end

      def running?
        thread = @mutex.synchronize { @thread }
        thread ? thread.alive? : false
      end

      def stopped?
        @mutex.synchronize { @stopped }
      end

      # Counters for observability and specs: completed / failed / dropped.
      def stats
        @mutex.synchronize { stats_snapshot }
      end

      private

      def stats_snapshot(abandoned: 0)
        { completed: @completed, failed: @failed, dropped: @dropped, abandoned: abandoned, pending: @queue.size }
      end

      # Block while the queue is full, up to `enqueue_timeout`. Returns the
      # admission decision (`:queued` / `:dropped` / `:rejected`) using the
      # same vocabulary as #submit. Caller holds @mutex.
      def wait_for_space(label)
        deadline = now + @enqueue_timeout

        while @queue.size >= @queue_limit
          remaining = deadline - now
          if remaining <= 0
            record_drop(label)
            return :dropped
          end

          @space_available.wait(@mutex, remaining)
          # Shutdown started while we waited — hand the write back so the
          # caller can run it inline instead of losing it.
          return :rejected if @stopped
        end

        :queued
      end

      # Caller holds @mutex. Every drop is counted; only the announcement is
      # rate-limited, so a sustained outage cannot flood the log pipeline.
      def record_drop(label)
        @dropped += 1
        return unless @last_drop_warn_at.nil? || (now - @last_drop_warn_at) >= DROP_WARN_INTERVAL

        @last_drop_warn_at = now
        announce_drop(label)
      end

      def announce_drop(label)
        return @on_drop.call(label, @dropped) if @on_drop

        warn "Magick: async write queue full (limit #{@queue_limit}), dropped write for " \
             "'#{Magick::LogSafe.sanitize(label)}' — #{@dropped} dropped so far"
      rescue StandardError
        nil # observability must never break the writer
      end

      # Caller holds @mutex. A forked child inherits the parent's queue but not
      # its worker thread; the parent owns those writes, so the child starts
      # from a clean queue rather than replaying them out of context.
      def reset_after_fork
        return if @owner_pid == Process.pid

        @queue.clear
        @thread = nil
        @owner_pid = Process.pid
        @stopped = false
      end

      # Caller holds @mutex. The worker's first act is to take @mutex, so it
      # simply waits until this method's caller lets go.
      def start_worker
        return if @thread&.alive?

        @thread = Thread.new { worker_loop }
        @thread.name = @name if @thread.respond_to?(:name=)
        @thread.abort_on_exception = false
        @thread
      end

      def worker_loop
        loop do
          entry = nil

          @mutex.synchronize do
            @work_available.wait(@mutex, IDLE_WAIT) while @queue.empty? && !@stopped
            # Drain the backlog before honouring the stop flag; shutdown kills
            # the thread if that takes longer than its timeout.
            return if @queue.empty?

            entry = @queue.shift
            @space_available.signal
          end

          execute(entry)
        end
      end

      def execute(entry)
        label, job = entry
        job.call
        @mutex.synchronize { @completed += 1 }
      rescue StandardError => e
        @mutex.synchronize { @failed += 1 }
        warn "Magick: async write failed for '#{Magick::LogSafe.sanitize(label)}': " \
             "#{e.class}: #{Magick::LogSafe.sanitize(e.message)}"
      end

      # Thread#join re-raises whatever killed the worker. Shutdown only cares
      # that the thread is gone, so a dead worker counts as joined.
      def join_quietly(thread, timeout)
        !thread.join(timeout).nil?
      rescue StandardError
        true
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def positive_integer(value, default)
        integer = value.to_i
        integer.positive? ? integer : default
      rescue NoMethodError
        default
      end

      def positive_float(value, default)
        float = value.to_f
        float.positive? ? float : default
      rescue NoMethodError
        default
      end
    end
  end
end
