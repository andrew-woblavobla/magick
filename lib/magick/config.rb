# frozen_string_literal: true

module Magick
  class Config
    attr_accessor :adapter_registry, :performance_metrics, :audit_log, :versioning, :warn_on_deprecated,
                  :async_updates, :memory_ttl, :circuit_breaker_threshold, :circuit_breaker_timeout, :redis_url, :redis_namespace, :redis_db, :environment, :active_record_model_class

    def initialize
      @warn_on_deprecated = false
      @async_updates = false
      @memory_ttl = 3600 # 1 hour
      @circuit_breaker_threshold = 5
      @circuit_breaker_timeout = 60
      @redis_namespace = 'magick:features'
      @redis_db = nil # Use default database (0) unless specified
      @environment = defined?(Rails) ? Rails.env.to_s : 'development'
    end

    # DSL methods for configuration
    def adapter(type, **options, &block)
      case type.to_sym
      when :memory
        configure_memory_adapter(**options)
      when :redis
        configure_redis_adapter(**options)
      when :active_record
        configure_active_record_adapter(**options)
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

    def redis(url: nil, namespace: nil, db: nil, **options)
      @redis_url = url if url
      @redis_namespace = namespace if namespace
      @redis_db = db if db
      redis_adapter = configure_redis_adapter(url: url, namespace: namespace, db: db, **options)

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
        active_record_adapter = configure_active_record_adapter if defined?(::ActiveRecord::Base)
        cb = Magick::CircuitBreaker.new(
          failure_threshold: @circuit_breaker_threshold,
          timeout: @circuit_breaker_timeout
        )
        @adapter_registry = Adapters::Registry.new(
          memory_adapter,
          redis_adapter,
          active_record_adapter: active_record_adapter,
          circuit_breaker: cb,
          async: @async_updates
        )
      end

      redis_adapter
    end

    def active_record(model_class: nil, primary: false, **options)
      @active_record_model_class = model_class if model_class
      @active_record_primary = primary
      active_record_adapter = configure_active_record_adapter(model_class: model_class, **options)

      # Automatically create Registry adapter if it doesn't exist
      if @adapter_registry
        # If registry already exists, update it with the new Active Record adapter
        if active_record_adapter && @adapter_registry.is_a?(Adapters::Registry)
          @adapter_registry.instance_variable_set(:@active_record_adapter, active_record_adapter)
          # Update primary if specified
          @adapter_registry.instance_variable_set(:@primary, :active_record) if primary
        end
      else
        memory_adapter = configure_memory_adapter
        redis_adapter = configure_redis_adapter
        cb = Magick::CircuitBreaker.new(
          failure_threshold: @circuit_breaker_threshold,
          timeout: @circuit_breaker_timeout
        )
        primary_adapter = primary ? :active_record : :memory
        @adapter_registry = Adapters::Registry.new(
          memory_adapter,
          redis_adapter,
          active_record_adapter: active_record_adapter,
          circuit_breaker: cb,
          async: @async_updates,
          primary: primary_adapter
        )
      end

      active_record_adapter
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

    def configure_redis_adapter(url: nil, namespace: nil, db: nil, client: nil)
      return nil unless defined?(Redis)

      url ||= @redis_url
      namespace ||= @redis_namespace
      db ||= @redis_db

      redis_client = client || begin
        redis_options = {}

        if url
          # Parse URL to extract database number if present
          parsed_url = begin
            URI.parse(url)
          rescue StandardError
            nil
          end
          db_from_url = nil
          if parsed_url && parsed_url.path && parsed_url.path.length > 1
            # Redis URL format: redis://host:port/db_number
            db_from_url = parsed_url.path[1..-1].to_i
          end

          # Use db parameter if provided, otherwise use db from URL, otherwise nil (default DB 0)
          final_db = db || db_from_url
          redis_options[:db] = final_db if final_db
          redis_options[:url] = url
          ::Redis.new(redis_options)
        else
          redis_options[:db] = db if db
          ::Redis.new(redis_options)
        end
      rescue StandardError
        nil
      end

      return nil unless redis_client

      # If db was specified but not in URL, select it explicitly
      # This handles cases where URL doesn't include db number
      if db && url
        parsed_url = begin
          URI.parse(url)
        rescue StandardError
          nil
        end
        url_has_db = parsed_url && parsed_url.path && parsed_url.path.length > 1
        unless url_has_db
          begin
            redis_client.select(db)
          rescue StandardError
            # Ignore if SELECT fails (some Redis setups don't support SELECT, e.g., Redis Cluster)
          end
        end
      end

      adapter = Adapters::Redis.new(redis_client)
      adapter.instance_variable_set(:@namespace, namespace) if namespace
      adapter
    end

    def configure_active_record_adapter(model_class: nil, **_options)
      return nil unless defined?(::ActiveRecord::Base)

      model_class ||= @active_record_model_class
      Adapters::ActiveRecord.new(model_class: model_class)
    rescue StandardError => e
      if defined?(Rails) && Rails.env.development?
        warn "Magick: Failed to initialize ActiveRecord adapter: #{e.message}"
      end
      nil
    end

    def configure_registry_adapter(memory: nil, redis: nil, active_record: nil, async: nil, circuit_breaker: nil,
                                   primary: nil)
      memory_adapter = memory || configure_memory_adapter
      redis_adapter = redis || configure_redis_adapter
      active_record_adapter = active_record || configure_active_record_adapter

      cb = circuit_breaker || Magick::CircuitBreaker.new(
        failure_threshold: @circuit_breaker_threshold,
        timeout: @circuit_breaker_timeout
      )

      async_enabled = async.nil? ? @async_updates : async
      primary_adapter = primary || (@active_record_primary ? :active_record : :memory)

      @adapter_registry = Adapters::Registry.new(
        memory_adapter,
        redis_adapter,
        active_record_adapter: active_record_adapter,
        circuit_breaker: cb,
        async: async_enabled,
        primary: primary_adapter
      )
    end

    def default_adapter_registry
      @default_adapter_registry ||= begin
        memory_adapter = Adapters::Memory.new
        redis_adapter = configure_redis_adapter
        active_record_adapter = configure_active_record_adapter if defined?(::ActiveRecord::Base)
        Adapters::Registry.new(memory_adapter, redis_adapter, active_record_adapter: active_record_adapter)
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
