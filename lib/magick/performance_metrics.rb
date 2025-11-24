# frozen_string_literal: true

module Magick
  class PerformanceMetrics
    class Metric
      attr_reader :feature_name, :operation, :duration, :timestamp, :success

      def initialize(feature_name, operation, duration, success: true)
        @feature_name = feature_name.to_s
        @operation = operation.to_s
        @duration = duration
        @timestamp = Time.now
        @success = success
      end

      def to_h
        {
          feature_name: feature_name,
          operation: operation,
          duration: duration,
          timestamp: timestamp.iso8601,
          success: success
        }
      end
    end

    def initialize(batch_size: 100, flush_interval: 60, redis_enabled: nil)
      @metrics = []
      @mutex = Mutex.new
      @usage_count = Hash.new(0) # Memory-only counts (reset on each process boot)
      @pending_updates = Hash.new(0) # For Redis batching (reset on each process boot)
      @flushed_counts = Hash.new(0) # Track counts that have been flushed to Redis (to avoid double-counting)
      @batch_size = batch_size
      @flush_interval = flush_interval
      @last_flush = Time.now
      # If redis_enabled is explicitly set, use it; otherwise default to false
      # It will be enabled later via enable_redis_tracking if Redis adapter is available
      @redis_enabled = redis_enabled.nil? ? false : redis_enabled
      # Cache expensive checks for performance
      @_rails_events_enabled = defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
      @_adapter_available = nil # Will be cached on first check
      @_redis_available = nil # Will be cached on first check

      # Async recording queue for non-blocking metrics
      @async_queue = Queue.new
      @async_thread = nil
      @async_enabled = true # Enable async by default for performance
      start_async_processor
    end

    # Public accessor for redis_enabled
    attr_reader :redis_enabled

    def record(feature_name, operation, duration, success: true)
      # Fast path: push to async queue (non-blocking, zero overhead in hot path)
      # Queue#<< is thread-safe and lock-free - extremely fast!
      return unless @async_enabled

      # Push to async queue - this is lock-free and extremely fast
      # Use non-blocking push (will raise if queue is full, but our queue is unbounded)
      begin
        @async_queue << [feature_name.to_s, operation.to_s, duration, success]
      rescue ThreadError, ClosedQueueError
        # Queue is closed or thread died, disable async
        @async_enabled = false
      end

      nil
    end

    # Internal: Process metrics from async queue (runs in background thread)
    def process_async_record(feature_name_str, operation_str, duration, success)
      # Minimize mutex lock time - only update counters
      pending_count = nil
      total_pending = nil
      @mutex.synchronize do
        # Only create Metric object if we're keeping metrics in memory
        if @metrics.length < 1000
          metric = Metric.new(feature_name_str, operation_str, duration, success: success)
          @metrics << metric
        end
        @usage_count[feature_name_str] += 1
        @pending_updates[feature_name_str] += 1
        pending_count = @pending_updates[feature_name_str]
        total_pending = @pending_updates.values.sum
        # Keep only last 1000 metrics (as a safety limit)
        @metrics.shift if @metrics.length > 1000
      end

      # Rails 8+ event for usage tracking (cached check)
      if @_rails_events_enabled
        Magick::Rails::Events.usage_tracked(feature_name_str, operation: operation_str, duration: duration,
                                                              success: success)
      end

      # Batch flush check - only if we're close to batch size
      flush_to_redis_if_needed if pending_count >= @batch_size || total_pending >= @batch_size
    end

    # Start background thread to process async metrics
    def start_async_processor
      return if @async_thread&.alive?

      @async_thread = Thread.new do
        last_flush_check = Time.now
        loop do
          # Wait for metrics with timeout to allow periodic flush checks
          # Queue#pop with timeout returns nil on timeout, raises on closed queue
          begin
            data = @async_queue.pop(timeout: 1.0)
          rescue ThreadError => e
            # Queue closed or thread interrupted
            break if e.message.include?('queue closed')

            raise
          end

          if data
            feature_name_str, operation_str, duration, success = data
            process_async_record(feature_name_str, operation_str, duration, success)
            last_flush_check = Time.now
          elsif Time.now - last_flush_check >= 1.0
            # Timeout - check if we need to flush based on time (every second)
            flush_to_redis_if_needed
            last_flush_check = Time.now
          end
        rescue StandardError => e
          # Log error but continue processing
          warn "Magick: Error in async metrics processor: #{e.message}" if defined?(Rails) && Rails.env.development?
          sleep 0.1 # Brief pause on error
        end
      end
      @async_thread.abort_on_exception = false
    end

    def flush_to_redis_if_needed
      # Cache adapter availability check (expensive)
      if @_adapter_available.nil?
        adapter = Magick.adapter_registry || Magick.default_adapter_registry
        @_adapter_available = adapter
        @_redis_available = adapter.is_a?(Magick::Adapters::Registry) && adapter.redis_available? if adapter
      end

      return unless @_adapter_available
      return unless @_redis_available || @redis_enabled
      return if @pending_updates.empty?

      should_flush = false
      @mutex.synchronize do
        # Flush if we have enough pending updates (sum of all counts) or enough time has passed
        # Check total count of pending updates, not just number of keys
        total_pending_count = @pending_updates.values.sum
        should_flush = true if total_pending_count >= @batch_size || (Time.now - @last_flush) >= @flush_interval
      end

      flush_to_redis if should_flush
    end

    # Force flush pending updates to Redis immediately
    # Useful when you need up-to-date stats across processes
    def force_flush_to_redis
      return if @pending_updates.empty?

      flush_to_redis
    end

    def flush_to_redis
      updates_to_flush = nil
      duration_stats_to_flush = {}
      @mutex.synchronize do
        return if @pending_updates.empty?

        updates_to_flush = @pending_updates.dup
        flushed_feature_names = updates_to_flush.keys.to_set
        @pending_updates.clear
        # Track what we're flushing so we don't double-count in usage_count
        updates_to_flush.each do |feature_name, count|
          @flushed_counts[feature_name] += count
        end

        # Collect duration stats for flushed features
        # Group metrics by feature_name and operation, sum durations and count occurrences
        @metrics.each do |metric|
          next unless flushed_feature_names.include?(metric.feature_name) && metric.success

          key = "#{metric.feature_name}:#{metric.operation}"
          duration_stats_to_flush[key] ||= { sum: 0.0, count: 0, feature_name: metric.feature_name,
                                             operation: metric.operation }
          duration_stats_to_flush[key][:sum] += metric.duration
          duration_stats_to_flush[key][:count] += 1
        end

        # Remove metrics for flushed features from memory to reduce memory usage
        # Metrics are already persisted in Redis, so we don't need to keep them in memory
        @metrics.reject! { |m| flushed_feature_names.include?(m.feature_name) }

        @last_flush = Time.now
      end

      return if updates_to_flush.nil? || updates_to_flush.empty?

      # Update Redis in batch
      # Always try to flush if Redis adapter is available, regardless of @redis_enabled flag
      # This ensures stats are collected even if redis_enabled wasn't set correctly
      begin
        adapter = Magick.adapter_registry || Magick.default_adapter_registry
        if adapter.is_a?(Magick::Adapters::Registry) && adapter.redis_available?
          redis = adapter.redis_client
          if redis
            # Flush usage counts
            updates_to_flush.each do |feature_name, count|
              redis_key = "magick:stats:#{feature_name}"
              redis.incrby(redis_key, count)
              redis.expire(redis_key, 86_400 * 7) # Keep stats for 7 days
            end

            # Flush duration stats (sum and count for calculating averages)
            duration_stats_to_flush.each do |_key, stats|
              sum_key = "magick:duration:sum:#{stats[:feature_name]}:#{stats[:operation]}"
              count_key = "magick:duration:count:#{stats[:feature_name]}:#{stats[:operation]}"
              redis.incrbyfloat(sum_key, stats[:sum])
              redis.incrby(count_key, stats[:count])
              redis.expire(sum_key, 86_400 * 7) # Keep stats for 7 days
              redis.expire(count_key, 86_400 * 7)
            end

            # Auto-enable redis tracking if we successfully flushed to Redis
            # This ensures redis_enabled is set correctly even if config didn't work
            @redis_enabled ||= true
          end
        end
      rescue StandardError => e
        # Silently fail - don't break feature checks if stats fail
        warn "Magick: Failed to flush stats to Redis: #{e.message}" if defined?(Rails) && Rails.env.development?
      end
    end

    def enable_redis_tracking(enable: true)
      old_value = @redis_enabled
      @redis_enabled = enable

      # Flush any pending updates when enabling
      if enable && !@pending_updates.empty?
        begin
          flush_to_redis
        rescue StandardError => e
          # Don't fail if flush fails - the flag is still set
          if defined?(Rails) && Rails.env.development?
            warn "Magick: Failed to flush stats when enabling Redis tracking: #{e.message}"
          end
        end
      end

      # Verify the value was set (for debugging)
      if !(@redis_enabled == enable) && defined?(Rails) && Rails.env.development?
        warn "Magick: Failed to set redis_enabled to #{enable}, current value: #{@redis_enabled}"
      end

      true
    end

    def average_duration(feature_name: nil, operation: nil)
      # Calculate from memory metrics (current process, not yet flushed)
      filtered = @metrics.select do |m|
        (feature_name.nil? || m.feature_name == feature_name.to_s) &&
          (operation.nil? || m.operation == operation.to_s) &&
          m.success
      end

      memory_sum = filtered.sum(&:duration)
      memory_count = filtered.length

      # Also get from Redis if available (persisted across processes)
      redis_sum = 0.0
      redis_count = 0
      begin
        adapter = Magick.adapter_registry || Magick.default_adapter_registry
        if adapter.is_a?(Magick::Adapters::Registry) && adapter.redis_available?
          redis = adapter.redis_client
          if redis
            if feature_name && operation
              # Specific feature and operation
              sum_key = "magick:duration:sum:#{feature_name}:#{operation}"
              count_key = "magick:duration:count:#{feature_name}:#{operation}"
              redis_sum = redis.get(sum_key).to_f
              redis_count = redis.get(count_key).to_i
            elsif feature_name
              # All operations for this feature
              pattern = "magick:duration:sum:#{feature_name}:*"
              redis.keys(pattern).each do |sum_key|
                op = sum_key.to_s.sub("magick:duration:sum:#{feature_name}:", '')
                count_key = "magick:duration:count:#{feature_name}:#{op}"
                redis_sum += redis.get(sum_key).to_f
                redis_count += redis.get(count_key).to_i
              end
            else
              # All features and operations (not recommended, but supported)
              redis.keys('magick:duration:sum:*').each do |sum_key|
                count_key = sum_key.to_s.sub(':sum:', ':count:')
                redis_sum += redis.get(sum_key).to_f
                redis_count += redis.get(count_key).to_i
              end
            end
          end
        end
      rescue StandardError
        # Silently fail
      end

      total_sum = memory_sum + redis_sum
      total_count = memory_count + redis_count

      return 0.0 if total_count == 0

      total_sum / total_count.to_f
    end

    def usage_count(feature_name)
      feature_name_str = feature_name.to_s

      # Force flush any pending updates for this feature before reading to ensure accuracy
      # This ensures stats are synced across processes immediately
      force_flush_to_redis if @pending_updates[feature_name_str] && @pending_updates[feature_name_str] > 0

      # Memory count = total counts in current process minus what we've already flushed
      # This avoids double-counting with Redis
      memory_count = (@usage_count[feature_name_str] || 0) - (@flushed_counts[feature_name_str] || 0)
      memory_count = 0 if memory_count < 0 # Safety check

      # Redis count = total counts from all processes (including this process's flushed counts)
      redis_count = 0
      begin
        adapter = Magick.adapter_registry || Magick.default_adapter_registry
        if adapter.is_a?(Magick::Adapters::Registry) && adapter.redis_available?
          redis = adapter.redis_client
          if redis
            redis_key = "magick:stats:#{feature_name_str}"
            redis_count = redis.get(redis_key).to_i
          end
        end
      rescue StandardError
        # Silently fail
      end

      # Total = Redis (all processes, all time) + memory (current process, not yet flushed)
      redis_count + memory_count
    end

    def most_used_features(limit: 10)
      # Combine memory and Redis counts
      combined_counts = @usage_count.dup

      # Always check Redis if adapter is available (not just if @redis_enabled)
      # This ensures we get the full count even if redis_enabled flag wasn't set correctly
      begin
        adapter = Magick.adapter_registry || Magick.default_adapter_registry
        if adapter.is_a?(Magick::Adapters::Registry) && adapter.redis_available?
          redis = adapter.redis_client
          if redis
            # Get all stats keys
            redis.keys('magick:stats:*').each do |key|
              feature_name = key.to_s.sub('magick:stats:', '')
              redis_count = redis.get(key).to_i
              combined_counts[feature_name] = (combined_counts[feature_name] || 0) + redis_count
            end
          end
        end
      rescue StandardError
        # Silently fail
      end

      combined_counts.sort_by { |_name, count| -count }.first(limit).to_h
    end

    def clear!
      @mutex.synchronize do
        @metrics.clear
        @usage_count.clear
        @pending_updates.clear
        @flushed_counts.clear
      end
    end

    # Stop async processor (for cleanup)
    def stop_async_processor
      @async_enabled = false
      @async_queue.close if @async_queue.respond_to?(:close)
      @async_thread&.kill
      @async_thread = nil
    end
  end
end
