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

    # enabled:     false disables audit logging entirely (Magick.audit_log is nil).
    # adapter:     optional host-supplied sink; receives #append(entry) for every entry.
    # retention:   entries kept per feature in the durable, shared store.
    # max_entries: entries kept in the per-process ring, across all features.
    # persist:     false keeps the ring (and any host adapter) but writes nothing
    #              to Redis/ActiveRecord — for hosts whose own adapter is the
    #              system of record.
    def audit_log(enabled: true, adapter: nil, retention: AuditLog::DEFAULT_RETENTION,
                  max_entries: AuditLog::DEFAULT_MAX_ENTRIES, persist: true)
      @audit_log_configured = true
      @audit_log = if enabled
                     AuditLog.new(adapter, max_entries: max_entries, retention: retention, persist: persist)
                   end
    end

    def versioning(enabled: true, max_versions: Versioning::DEFAULT_MAX_VERSIONS)
      @versioning_enabled = enabled
      @versioning = if enabled
                      Versioning.new(adapter_registry || default_adapter_registry, max_versions: max_versions)
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

    # How a prerequisite that exists neither in this process nor in the shared
    # backend is treated: :satisfied (default, ignore it) or :unsatisfied
    # (evaluate the dependent feature as off). See Magick.unknown_dependency_policy.
    def unknown_dependency_policy(policy = nil)
      return @unknown_dependency_policy if policy.nil?

      unless Magick::UNKNOWN_DEPENDENCY_POLICIES.include?(policy.to_sym)
        raise ArgumentError,
              "unknown_dependency_policy must be one of #{Magick::UNKNOWN_DEPENDENCY_POLICIES.inspect}, " \
              "got #{policy.inspect}"
      end

      @unknown_dependency_policy = policy.to_sym
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

      # Read the ivars directly: calling the DSL methods here would re-run
      # them with their defaults and stomp explicit `enabled: false` settings.
      # Assign even when nil: `audit_log enabled: false` has to clear the
      # default instance Magick.configure creates, or opting out would leave
      # audit entries being written (durably, now) anyway.
      Magick.audit_log = @audit_log if @audit_log || @audit_log_configured
      Magick.versioning = @versioning if @versioning
      Magick.versioning_enabled = @versioning_enabled unless @versioning_enabled.nil?
      Magick.unknown_dependency_policy = @unknown_dependency_policy if @unknown_dependency_policy
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

    # Timeouts are always explicit — see Adapters::Redis::DEFAULT_TIMEOUTS for
    # why. Callers can override any of the three (`redis url: ..., read_timeout: 3`)
    # but cannot end up with none.
    def configure_redis_adapter(url: nil, namespace: nil, db: nil, client: nil, **timeouts)
      return nil unless defined?(Redis)

      url ||= @redis_url
      namespace ||= @redis_namespace
      db ||= @redis_db
      timeouts = Adapters::Redis::DEFAULT_TIMEOUTS.merge(
        timeouts.slice(*Adapters::Redis::DEFAULT_TIMEOUTS.keys)
      )

      redis_client = client || begin
        redis_options = timeouts.dup

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

    # Explicitly configured project root, if any. Set it with
    # `Magick::ConfigDSL.project_root = '/srv/app'` — never from untrusted
    # input.
    @project_root = nil

    class << self
      attr_writer :project_root
    end

    # The directory a config file must live under.
    #
    # Rails.root when the host is a Rails app, otherwise the Bundler project
    # (the directory holding the Gemfile). Deliberately *not* Dir.pwd: a
    # process started from `/`, or one that chdirs after boot, must not be
    # able to widen the guard in front of the eval sink below.
    #
    # Returns nil when no root can be determined; the loader then refuses
    # every path unless MAGICK_ALLOW_CONFIG_EVAL=1 is set. Apps that run
    # outside both Rails and Bundler can assign a root explicitly with
    # `Magick::ConfigDSL.project_root = '/srv/app'` — never from untrusted
    # input.
    def self.project_root
      root = @project_root || detect_project_root
      return nil if root.nil? || root.to_s.empty?

      real_path(root.to_s)
    end

    def self.detect_project_root
      if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.to_s
      elsif defined?(::Bundler) && ::Bundler.respond_to?(:root)
        begin
          ::Bundler.root.to_s
        rescue StandardError
          nil
        end
      end
    end
    private_class_method :detect_project_root

    # Symlink-resolved form of a directory, so the root and the candidate
    # path are compared in the same namespace (Capistrano-style
    # `current -> releases/x` deploys would otherwise never match).
    def self.real_path(path)
      File.realpath(path)
    rescue StandardError
      File.expand_path(path)
    end
    private_class_method :real_path

    # Separator-aware containment: `/srv/app-evil` is not inside `/srv/app`,
    # and a root of `/` is treated as no containment at all rather than as a
    # prefix every absolute path satisfies.
    def self.inside_project_root?(resolved, root)
      return false if root.nil?

      base = root.chomp(File::SEPARATOR)
      return false if base.empty?

      resolved == base || resolved.start_with?(base + File::SEPARATOR)
    end
    private_class_method :inside_project_root?

    # Load a Magick configuration DSL file by path.
    #
    # SECURITY: This method evaluates the file's contents as Ruby via
    # instance_eval. Never pass a path derived from HTTP input, ENV
    # variables, build artifacts, or any other untrusted source — doing so
    # is remote code execution. Callers must guarantee the path points at a
    # file that lives inside the project tree (typical use:
    # Rails.root.join('config/features.rb')).
    #
    # The path is resolved with File.realpath and must sit inside
    # `project_root` (see above). Setting MAGICK_ALLOW_CONFIG_EVAL=1 skips
    # the check entirely and is dangerous: it hands any caller that can
    # influence `file_path` arbitrary code execution. Use it only for a
    # trusted file you deliberately keep outside the project tree.
    def self.load_from_file(file_path)
      resolved = File.realpath(file_path)

      unless ENV['MAGICK_ALLOW_CONFIG_EVAL'] == '1'
        root = project_root
        unless inside_project_root?(resolved, root)
          raise SecurityError,
                'Refusing to load Magick config from outside the project tree ' \
                "(#{root || 'project root could not be determined'}): #{resolved}. " \
                'Set MAGICK_ALLOW_CONFIG_EVAL=1 to override (only if you trust the file).'
        end
      end

      config = Config.new
      config.instance_eval(File.read(resolved), resolved)
      config.apply!
      config
    end
  end
end
