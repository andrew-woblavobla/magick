# frozen_string_literal: true

module Magick
  class Config
    attr_accessor :adapter_registry, :performance_metrics, :audit_log, :versioning, :warn_on_deprecated,
                  :async_updates, :memory_ttl, :circuit_breaker_threshold, :circuit_breaker_timeout, :redis_url, :redis_namespace, :environment

    def initialize
      @warn_on_deprecated = false
      @async_updates = false
      @memory_ttl = 3600 # 1 hour
      @circuit_breaker_threshold = 5
      @circuit_breaker_timeout = 60
      @redis_namespace = 'magick:features'
      @environment = defined?(Rails) ? Rails.env.to_s : 'development'
    end

    # DSL methods for configuration
    def adapter(type, **options, &block)
      case type.to_sym
      when :memory
        configure_memory_adapter(**options)
      when :redis
        configure_redis_adapter(**options)
      when :registry
        if block_given?
          instance_eval(&block)
          configure_registry_adapter
        else
          configure_registry_adapter(**options)
        end
      else
        raise ArgumentError, "Unknown adapter type: #{type}"
      end
    end

    def memory(**options)
      configure_memory_adapter(**options)
    end

    def redis(url: nil, namespace: nil, **options)
      @redis_url = url if url
      @redis_namespace = namespace if namespace
      configure_redis_adapter(url: url, namespace: namespace, **options)
    end

    def performance_metrics(enabled: true, redis_tracking: nil, batch_size: 100, flush_interval: 60, **_options)
      return unless enabled

      @performance_metrics = PerformanceMetrics.new(batch_size: batch_size, flush_interval: flush_interval)
      # Enable Redis tracking if Redis adapter is configured (or explicitly set)
      if redis_tracking.nil?
        # Auto-enable if Redis adapter exists
        redis_tracking = !@redis_url.nil? || configure_redis_adapter != nil
      end
      @performance_metrics.enable_redis_tracking(enable: redis_tracking) if @performance_metrics
    end

    def audit_log(enabled: true, adapter: nil)
      @audit_log = if enabled
                     adapter ? AuditLog.new(adapter) : AuditLog.new
                   end
    end

    def versioning(enabled: true)
      @versioning = (Versioning.new(adapter_registry || default_adapter_registry) if enabled)
    end

    def circuit_breaker(threshold: nil, timeout: nil)
      @circuit_breaker_threshold = threshold if threshold
      @circuit_breaker_timeout = timeout if timeout
    end

    def async_updates(enabled: true)
      @async_updates = enabled
    end

    def memory_ttl(seconds)
      @memory_ttl = seconds
    end

    def warn_on_deprecated(enabled: true)
      @warn_on_deprecated = enabled
    end

    def environment(name)
      @environment = name.to_s
    end

    def apply!
      # Apply configuration to Magick module
      Magick.adapter_registry = adapter_registry if adapter_registry
      Magick.performance_metrics = performance_metrics if performance_metrics
      Magick.audit_log = audit_log if audit_log
      Magick.versioning = versioning if versioning
      Magick.warn_on_deprecated = warn_on_deprecated

      # Enable Redis tracking for performance metrics if Redis adapter is configured
      if Magick.performance_metrics && adapter_registry.is_a?(Adapters::Registry) && adapter_registry.redis_adapter
        Magick.performance_metrics.enable_redis_tracking(enable: true)
      end
    end

    private

    def configure_memory_adapter(ttl: nil)
      ttl ||= @memory_ttl
      adapter = Adapters::Memory.new
      # Set default TTL by updating the adapter's default_ttl
      adapter.instance_variable_set(:@default_ttl, ttl) if ttl
      adapter
    end

    def configure_redis_adapter(url: nil, namespace: nil, client: nil)
      return nil unless defined?(Redis)

      url ||= @redis_url
      namespace ||= @redis_namespace

      redis_client = client || begin
        if url
          ::Redis.new(url: url)
        else
          ::Redis.new
        end
      rescue StandardError
        nil
      end

      return nil unless redis_client

      adapter = Adapters::Redis.new(redis_client)
      adapter.instance_variable_set(:@namespace, namespace) if namespace
      adapter
    end

    def configure_registry_adapter(memory: nil, redis: nil, async: nil, circuit_breaker: nil)
      memory_adapter = memory || configure_memory_adapter
      redis_adapter = redis || configure_redis_adapter

      cb = circuit_breaker || CircuitBreaker.new(
        failure_threshold: @circuit_breaker_threshold,
        timeout: @circuit_breaker_timeout
      )

      async_enabled = async.nil? ? @async_updates : async

      @adapter_registry = Adapters::Registry.new(
        memory_adapter,
        redis_adapter,
        circuit_breaker: cb,
        async: async_enabled
      )
    end

    def default_adapter_registry
      @default_adapter_registry ||= begin
        memory_adapter = Adapters::Memory.new
        redis_adapter = configure_redis_adapter
        Adapters::Registry.new(memory_adapter, redis_adapter)
      end
    end
  end

  # DSL for configuration
  module ConfigDSL
    def self.configure(&block)
      config = Config.new
      config.instance_eval(&block)
      config.apply!
      config
    end

    def self.load_from_file(file_path)
      config = Config.new
      config.instance_eval(File.read(file_path), file_path)
      config.apply!
      config
    end
  end
end
