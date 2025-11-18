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

    def initialize
      @metrics = []
      @mutex = Mutex.new
      @usage_count = Hash.new(0)
    end

    def record(feature_name, operation, duration, success: true)
      metric = Metric.new(feature_name, operation, duration, success: success)
      @mutex.synchronize do
        @metrics << metric
        @usage_count[feature_name.to_s] += 1
        # Keep only last 1000 metrics
        @metrics.shift if @metrics.length > 1000
      end

      # Rails 8+ event for usage tracking
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.usage_tracked(feature_name, operation: operation, duration: duration, success: success)
      end

      metric
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
      @usage_count[feature_name.to_s] || 0
    end

    def most_used_features(limit: 10)
      @usage_count.sort_by { |_name, count| -count }.first(limit).to_h
    end

    def clear!
      @mutex.synchronize do
        @metrics.clear
        @usage_count.clear
      end
    end
  end
end
