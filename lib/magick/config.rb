# frozen_string_literal: true

module Magick
  class Config
    attr_accessor :adapter_registry, :performance_metrics, :audit_log, :versioning
    attr_accessor :warn_on_deprecated, :async_updates, :memory_ttl, :circuit_breaker_threshold
    attr_accessor :circuit_breaker_timeout, :redis_url, :redis_namespace, :environment

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

    def performance_metrics(enabled: true, **options)
      if enabled
        @performance_metrics = PerformanceMetrics.new
      else
        @performance_metrics = nil
      end
    end

    def audit_log(enabled: true, adapter: nil)
      if enabled
        @audit_log = adapter ? AuditLog.new(adapter) : AuditLog.new
      else
        @audit_log = nil
      end
    end

    def versioning(enabled: true)
      if enabled
        @versioning = Versioning.new(adapter_registry || default_adapter_registry)
      else
        @versioning = nil
      end
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
