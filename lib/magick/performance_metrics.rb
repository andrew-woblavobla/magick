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

    def initialize(batch_size: 100, flush_interval: 60)
      @metrics = []
      @mutex = Mutex.new
      @usage_count = Hash.new(0)
      @pending_updates = Hash.new(0) # For Redis batching
      @batch_size = batch_size
      @flush_interval = flush_interval
      @last_flush = Time.now
      @redis_enabled = false
    end

    def record(feature_name, operation, duration, success: true)
      feature_name_str = feature_name.to_s
      metric = Metric.new(feature_name_str, operation, duration, success: success)

      @mutex.synchronize do
        @metrics << metric
        @usage_count[feature_name_str] += 1
        @pending_updates[feature_name_str] += 1
        # Keep only last 1000 metrics
        @metrics.shift if @metrics.length > 1000
      end

      # Rails 8+ event for usage tracking
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.usage_tracked(feature_name, operation: operation, duration: duration, success: success)
      end

      # Batch flush to Redis if needed
      flush_to_redis_if_needed

      metric
    end

    def flush_to_redis_if_needed
      return unless @redis_enabled
      return if @pending_updates.empty?

      should_flush = false
      @mutex.synchronize do
        # Flush if we have enough pending updates or enough time has passed
        if @pending_updates.size >= @batch_size || (Time.now - @last_flush) >= @flush_interval
          should_flush = true
        end
      end

      flush_to_redis if should_flush
    end

    def flush_to_redis
      updates_to_flush = nil
      @mutex.synchronize do
        return if @pending_updates.empty?

        updates_to_flush = @pending_updates.dup
        @pending_updates.clear
        @last_flush = Time.now
      end

      return if updates_to_flush.nil? || updates_to_flush.empty?

      # Update Redis in batch
      begin
        adapter = Magick.adapter_registry || Magick.default_adapter_registry
        if adapter.is_a?(Magick::Adapters::Registry) && adapter.redis_adapter
          redis = adapter.redis_adapter.instance_variable_get(:@redis)
          if redis
            updates_to_flush.each do |feature_name, count|
              redis_key = "magick:stats:#{feature_name}"
              redis.incrby(redis_key, count)
              redis.expire(redis_key, 86400 * 7) # Keep stats for 7 days
            end
          end
        end
      rescue StandardError => e
        # Silently fail - don't break feature checks if stats fail
        warn "Magick: Failed to flush stats to Redis: #{e.message}" if defined?(Rails) && Rails.env.development?
      end
    end

    def enable_redis_tracking(enable: true)
      @redis_enabled = enable
      # Flush any pending updates when enabling
      flush_to_redis if enable && !@pending_updates.empty?
    end

    def average_duration(feature_name: nil, operation: nil)
      filtered = @metrics.select do |m|
        (feature_name.nil? || m.feature_name == feature_name.to_s) &&
          (operation.nil? || m.operation == operation.to_s) &&
          m.success
      end
      return 0.0 if filtered.empty?

      filtered.sum(&:duration) / filtered.length.to_f
    end

    def usage_count(feature_name)
      feature_name_str = feature_name.to_s
      memory_count = @usage_count[feature_name_str] || 0

      # Also check Redis if enabled
      redis_count = 0
      if @redis_enabled
        begin
          adapter = Magick.adapter_registry || Magick.default_adapter_registry
          if adapter.is_a?(Magick::Adapters::Registry) && adapter.redis_adapter
            redis = adapter.redis_adapter.instance_variable_get(:@redis)
            if redis
              redis_key = "magick:stats:#{feature_name_str}"
              redis_count = redis.get(redis_key).to_i
            end
          end
        rescue StandardError
          # Silently fail
        end
      end

      memory_count + redis_count
    end

    def most_used_features(limit: 10)
      # Combine memory and Redis counts
      combined_counts = @usage_count.dup

      if @redis_enabled
        begin
          adapter = Magick.adapter_registry || Magick.default_adapter_registry
          if adapter.is_a?(Magick::Adapters::Registry) && adapter.redis_adapter
            redis = adapter.redis_adapter.instance_variable_get(:@redis)
            if redis
              # Get all stats keys
              redis.keys("magick:stats:*").each do |key|
                feature_name = key.to_s.sub('magick:stats:', '')
                redis_count = redis.get(key).to_i
                combined_counts[feature_name] = (combined_counts[feature_name] || 0) + redis_count
              end
            end
          end
        rescue StandardError
          # Silently fail
        end
      end

      combined_counts.sort_by { |_name, count| -count }.first(limit).to_h
    end

    def clear!
      @mutex.synchronize do
        @metrics.clear
        @usage_count.clear
        @pending_updates.clear
      end
    end
  end
end
