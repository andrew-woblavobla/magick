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
      redis_adapter = configure_redis_adapter(url: url, namespace: namespace, **options)

      # Automatically create Registry adapter if it doesn't exist
      # This allows users to just call `redis url: ...` without needing to call `adapter :registry`
      if @adapter_registry
        # If registry already exists, update it with the new Redis adapter
        # This allows reconfiguring Redis without recreating the registry
        if redis_adapter && @adapter_registry.is_a?(Adapters::Registry)
          # Update the Redis adapter in the existing registry
          @adapter_registry.instance_variable_set(:@redis_adapter, redis_adapter)
          # Restart cache invalidation subscriber with new Redis adapter
          @adapter_registry.send(:start_cache_invalidation_subscriber) if redis_adapter
        end
      else
        memory_adapter = configure_memory_adapter
        cb = Magick::CircuitBreaker.new(
          failure_threshold: @circuit_breaker_threshold,
          timeout: @circuit_breaker_timeout
        )
        @adapter_registry = Adapters::Registry.new(
          memory_adapter,
          redis_adapter,
          circuit_breaker: cb,
          async: @async_updates
        )
      end

      redis_adapter
    end

    def performance_metrics(enabled: true, redis_tracking: nil, batch_size: 100, flush_interval: 60, **_options)
      return unless enabled

      # Store redis_tracking preference before creating instance
      @performance_metrics_redis_tracking = redis_tracking
      # Create instance with redis_enabled set if explicitly provided
      initial_redis_enabled = redis_tracking == true
      @performance_metrics = PerformanceMetrics.new(
        batch_size: batch_size,
        flush_interval: flush_interval,
        redis_enabled: initial_redis_enabled
      )
      # If explicitly set to false, disable it
      @performance_metrics.enable_redis_tracking(enable: false) if redis_tracking == false
      # If nil, will be auto-determined in apply! method
      @performance_metrics
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

      # Apply performance metrics (preserve redis_tracking setting)
      if performance_metrics
        Magick.performance_metrics = performance_metrics
        # Re-apply redis_tracking setting after assignment (in case object was replaced)
        if defined?(@performance_metrics_redis_tracking) && !@performance_metrics_redis_tracking.nil?
          # Explicitly set value takes precedence
          Magick.performance_metrics.enable_redis_tracking(enable: @performance_metrics_redis_tracking)
        # Otherwise, auto-enable if Redis adapter is configured
        # Check Magick.adapter_registry (after it's been set) instead of local instance variable
        elsif Magick.adapter_registry.is_a?(Adapters::Registry) && Magick.adapter_registry.redis_available?
          # Always enable if Redis adapter is available (unless explicitly disabled above)
          Magick.performance_metrics.enable_redis_tracking(enable: true)
        end
      elsif Magick.performance_metrics
        # If no new performance_metrics was configured, but one exists, still try to enable Redis tracking
        # if Redis adapter is available and redis_tracking wasn't explicitly disabled
        # Only auto-enable if not explicitly disabled
        if Magick.adapter_registry.is_a?(Adapters::Registry) && Magick.adapter_registry.redis_available? && !(defined?(@performance_metrics_redis_tracking) && @performance_metrics_redis_tracking == false)
          Magick.performance_metrics.enable_redis_tracking(enable: true)
        end
      end

      Magick.audit_log = audit_log if audit_log
      Magick.versioning = versioning if versioning
      Magick.warn_on_deprecated = warn_on_deprecated
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

      cb = circuit_breaker || Magick::CircuitBreaker.new(
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
