# frozen_string_literal: true

require 'digest'
require 'time'
require_relative '../magick/feature_variant'

module Magick
  class Feature
    VALID_TYPES = %i[boolean string number].freeze
    VALID_STATUSES = %i[active inactive deprecated].freeze
    # What "off" means per feature type — the value #disable writes.
    DISABLED_VALUES = { boolean: false, string: '', number: 0 }.freeze

    # Adapter keys holding the prerequisite set and the declaration that seeded
    # it. Both live next to the feature's other state, so dependencies travel
    # with the feature across processes and restarts.
    DEPENDENCIES_KEY = 'dependencies'
    DECLARED_DEPENDENCIES_KEY = 'declared_dependencies'

    # How long a prerequisite that exists nowhere stays cached as "unknown"
    # before the backend is probed again. Without it a misconfigured dependency
    # would cost a Redis/DB round trip on every evaluation.
    UNKNOWN_DEPENDENCY_RECHECK_SECONDS = 60.0

    attr_reader :name, :type, :status, :default_value, :description, :display_name, :group, :adapter_registry,
                :targeting

    def initialize(name, adapter_registry, **options)
      @name = name.to_s
      @adapter_registry = adapter_registry
      @type = (options[:type] || :boolean).to_sym
      @status = (options[:status] || :active).to_sym
      @default_value = options.fetch(:default_value, default_for_type)
      @description = options[:description]
      @display_name = options[:name] || options[:display_name]
      @group = options[:group]
      @targeting = {}
      # nil means this process declares nothing about dependencies, so it must
      # never overwrite what another process stored; [] is a real declaration
      # ("this feature has no prerequisites").
      @declared_dependencies = options[:dependencies] ? normalize_dependency_list(options[:dependencies]) : nil
      @dependencies = @declared_dependencies&.dup || []
      @stored_value_initialized = false # Track if @stored_value has been explicitly set

      # Performance optimizations: cache expensive checks
      @_targeting_empty = true # Will be updated after load_from_adapter
      @_rails_events_enabled = false # Cache Rails events availability (only enable in dev)
      @_perf_metrics_enabled = false # Cache performance metrics (disabled by default for speed)

      validate_type!
      validate_default_value!
      load_from_adapter
      # Update targeting empty cache after loading
      @_targeting_empty = @targeting.empty?
      # Cache performance metrics availability (check once, not on every call)
      # Only enable if performance_metrics exists AND is actually being used
      @_perf_metrics_enabled = !Magick.performance_metrics.nil?
      # Save description and display_name to adapter if they were provided and not already in adapter
      save_metadata_if_new
    end

    def enabled?(context = {})
      # Check performance metrics dynamically (in case enabled after feature creation)
      # But cache the check result for performance
      perf_metrics = Magick.performance_metrics
      perf_metrics_enabled = !perf_metrics.nil?

      # Update cached flag if it changed
      @_perf_metrics_enabled = perf_metrics_enabled if @_perf_metrics_enabled != perf_metrics_enabled

      # Fast path: if performance metrics disabled, skip all overhead
      return check_enabled(context) unless perf_metrics_enabled

      # Performance metrics enabled: measure and record
      # Use inline timing to avoid function call overhead
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = check_enabled(context)
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000 # milliseconds

      # Record metrics (fast path - minimal overhead)
      perf_metrics.record(name, 'enabled?', duration, success: true)

      # Rails 8+ events (only in development or when explicitly enabled)
      if @_rails_events_enabled
        if result
          Magick::Rails::Events.feature_enabled(name, context: context)
        else
          Magick::Rails::Events.feature_disabled(name, context: context)
        end
      end

      # Warn if deprecated (only if enabled)
      if status == :deprecated && result && !context[:allow_deprecated] && Magick.warn_on_deprecated
        warn "DEPRECATED: Feature '#{name}' is deprecated and will be removed."
        Magick::Rails::Events.deprecated_warning(name) if @_rails_events_enabled
      end

      result
    rescue StandardError => e
      # Record error metrics if enabled
      if perf_metrics_enabled && perf_metrics
        duration = defined?(start_time) && start_time ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000 : 0.0
        perf_metrics.record(name, 'enabled?', duration, success: false)
      end
      # Return false on any error (fail-safe)
      warn "Magick: Error checking feature '#{Magick::LogSafe.sanitize(name)}': #{Magick::LogSafe.sanitize(e.message)}" if defined?(Rails) && Rails.env.development?
      false
    end

    def check_enabled(context = {})
      # Dup context to avoid mutating the caller's hash
      context = context.dup

      # Extract context from user object if provided
      # This allows Magick.enabled?(:feature, user: player) to work
      if context[:user]
        extracted = extract_context_from_object(context.delete(:user))
        # Merge extracted context, but don't override explicit values already in context
        extracted.each do |key, value|
          context[key] = value unless context.key?(key)
        end
      end

      # Fast path: check status first
      return false if status == :inactive
      return false if status == :deprecated && !context[:allow_deprecated]

      # Dependency check: a feature with unmet prerequisites evaluates as disabled,
      # regardless of its own configured state. Evaluation-only — prerequisite state
      # is never written into this feature.
      return false unless dependencies_satisfied?(context)

      # Fast path: skip targeting checks if targeting is empty (most common case)
      unless @_targeting_empty
        # Check exclusions FIRST — exclusions always take priority over inclusions
        return false if excluded?(context)

        # Check date/time range targeting
        return false if targeting[:date_range] && !date_range_active?(targeting[:date_range])

        # Check IP address targeting
        return false if targeting[:ip_address] && context[:ip_address] && !ip_address_matches?(context[:ip_address])

        # Check custom attributes
        return false if targeting[:custom_attributes] && !custom_attributes_match?(context,
                                                                                   targeting[:custom_attributes])

        # Check complex conditions
        return false if targeting[:complex_conditions] && !complex_conditions_match?(context,
                                                                                     targeting[:complex_conditions])

        # Check user/group/role/percentage targeting
        targeting_result = check_targeting(context)
        return false if targeting_result.nil?
        # Targeting doesn't match - return false

        # Targeting matches - for boolean features, return true directly
        # For string/number features, still check the value
        return true if type == :boolean
        # For string/number, continue to check value below

      end

      # Get value and check based on type
      value = get_value(context)
      case type
      when :boolean
        value == true
      when :string
        !value.nil? && value != ''
      when :number
        value.to_f.positive?
      else
        false
      end
    rescue StandardError => e
      # Return false on any error (fail-safe)
      warn "Magick: Error in check_enabled for '#{Magick::LogSafe.sanitize(name)}': #{Magick::LogSafe.sanitize(e.message)}" if defined?(Rails) && Rails.env.development?
      false
    end

    def disabled?(context = {})
      !enabled?(context)
    end

    def enabled_for?(object, **additional_context)
      # Extract context from object
      context = extract_context_from_object(object)
      # Merge with any additional context provided
      context.merge!(additional_context)
      enabled?(context)
    end

    def disabled_for?(object, **additional_context)
      !enabled_for?(object, **additional_context)
    end

    def value(context = {})
      get_value(context)
    end

    def get_value(context = {})
      # Fast path: check targeting rules first (only if targeting exists)
      unless @_targeting_empty
        targeting_result = check_targeting(context)
        # If targeting matches (returns truthy), return the stored value
        # If targeting doesn't match (returns nil), continue to return default value
        unless targeting_result.nil?
          # Targeting matches - return stored value (or load it if not initialized)
          return @stored_value if @stored_value_initialized

          # Load from adapter
          loaded_value = load_value_from_adapter
          if loaded_value.nil?
            # Value not found in adapter, use default and cache it
            @stored_value = default_value
            @stored_value_initialized = true
            return default_value
          else
            # Value found in adapter, use it and mark as initialized
            @stored_value = loaded_value
            @stored_value_initialized = true
            return loaded_value
          end

        end
        # Targeting doesn't match - return default value
        return default_value
      end

      # Fast path: use cached value if initialized (avoid adapter calls)
      return @stored_value if @stored_value_initialized

      # Load from adapter if instance variable hasn't been initialized
      loaded_value = load_value_from_adapter
      if loaded_value.nil?
        # Value not found in adapter, use default and cache it
        @stored_value = default_value
        @stored_value_initialized = true
        default_value
      else
        # Value found in adapter, use it and mark as initialized
        @stored_value = loaded_value
        @stored_value_initialized = true
        loaded_value
      end
    rescue StandardError => e
      # Return default value on error (fail-safe)
      warn "Magick: Error in get_value for '#{Magick::LogSafe.sanitize(name)}': #{Magick::LogSafe.sanitize(e.message)}" if defined?(Rails) && Rails.env.development?
      default_value
    end

    def enable_for_user(user_id)
      record_change('enable_for_user', targeting_change(:user, added: user_id)) do
        enable_targeting(:user, user_id)
      end
      true
    end

    def disable_for_user(user_id)
      record_change('disable_for_user', targeting_change(:user, removed: user_id)) do
        disable_targeting(:user, user_id)
      end
      true
    end

    def enable_for_group(group_name)
      record_change('enable_for_group', targeting_change(:group, added: group_name)) do
        enable_targeting(:group, group_name)
      end
      true
    end

    def disable_for_group(group_name)
      record_change('disable_for_group', targeting_change(:group, removed: group_name)) do
        disable_targeting(:group, group_name)
      end
      true
    end

    def enable_for_role(role_name)
      record_change('enable_for_role', targeting_change(:role, added: role_name)) do
        enable_targeting(:role, role_name)
      end
      true
    end

    def disable_for_role(role_name)
      record_change('disable_for_role', targeting_change(:role, removed: role_name)) do
        disable_targeting(:role, role_name)
      end
      true
    end

    def enable_for_tag(tag_name)
      record_change('enable_for_tag', targeting_change(:tag, added: tag_name)) do
        enable_targeting(:tag, tag_name)
      end
      true
    end

    def disable_for_tag(tag_name)
      record_change('disable_for_tag', targeting_change(:tag, removed: tag_name)) do
        disable_targeting(:tag, tag_name)
      end
      true
    end

    # --- Exclusion methods ---

    def exclude_user(user_id)
      record_change('exclude_user', targeting_change(:excluded_users, added: user_id)) do
        enable_targeting(:excluded_users, user_id)
      end
      true
    end

    def remove_user_exclusion(user_id)
      record_change('remove_user_exclusion', targeting_change(:excluded_users, removed: user_id)) do
        disable_targeting(:excluded_users, user_id)
      end
      true
    end

    def exclude_tag(tag_name)
      record_change('exclude_tag', targeting_change(:excluded_tags, added: tag_name)) do
        enable_targeting(:excluded_tags, tag_name)
      end
      true
    end

    def remove_tag_exclusion(tag_name)
      record_change('remove_tag_exclusion', targeting_change(:excluded_tags, removed: tag_name)) do
        disable_targeting(:excluded_tags, tag_name)
      end
      true
    end

    def exclude_group(group_name)
      record_change('exclude_group', targeting_change(:excluded_groups, added: group_name)) do
        enable_targeting(:excluded_groups, group_name)
      end
      true
    end

    def remove_group_exclusion(group_name)
      record_change('remove_group_exclusion', targeting_change(:excluded_groups, removed: group_name)) do
        disable_targeting(:excluded_groups, group_name)
      end
      true
    end

    def exclude_role(role_name)
      record_change('exclude_role', targeting_change(:excluded_roles, added: role_name)) do
        enable_targeting(:excluded_roles, role_name)
      end
      true
    end

    def remove_role_exclusion(role_name)
      record_change('remove_role_exclusion', targeting_change(:excluded_roles, removed: role_name)) do
        disable_targeting(:excluded_roles, role_name)
      end
      true
    end

    def exclude_ip_addresses(ip_addresses)
      ips = Array(ip_addresses).map(&:to_s)
      record_change('exclude_ip_addresses', targeting_change(:excluded_ip_addresses, added: ips)) do
        # excluded_ip_addresses is stored as a flat Array of strings; bypass the
        # generic enable_targeting path whose "array type" branch stringifies the
        # incoming array into a single element.
        @targeting[:excluded_ip_addresses] ||= []
        ips.each do |str|
          @targeting[:excluded_ip_addresses] << str unless @targeting[:excluded_ip_addresses].include?(str)
        end
        save_targeting
      end
      true
    end

    def remove_ip_exclusion
      record_change('remove_ip_exclusion', targeting_change(:excluded_ip_addresses)) do
        disable_targeting(:excluded_ip_addresses)
      end
      true
    end

    def enable_percentage_of_users(percentage)
      record_change('enable_percentage_of_users', targeting_change(:percentage_users, added: percentage.to_f)) do
        @targeting[:percentage_users] = percentage.to_f
        save_targeting

        # Update registered feature instance if it exists
        Magick.features[name].instance_variable_set(:@targeting, @targeting.dup) if Magick.features.key?(name)

        # Rails 8+ event
        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.targeting_added(name, targeting_type: :percentage_users, targeting_value: percentage)
        end
      end

      true
    end

    def disable_percentage_of_users
      record_change('disable_percentage_of_users', targeting_change(:percentage_users)) do
        disable_targeting(:percentage_users)
      end
      true
    end

    def enable_percentage_of_requests(percentage)
      record_change('enable_percentage_of_requests', targeting_change(:percentage_requests, added: percentage.to_f)) do
        @targeting[:percentage_requests] = percentage.to_f
        save_targeting

        # Update registered feature instance if it exists
        Magick.features[name].instance_variable_set(:@targeting, @targeting.dup) if Magick.features.key?(name)

        # Rails 8+ event
        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.targeting_added(name, targeting_type: :percentage_requests, targeting_value: percentage)
        end
      end

      true
    end

    def disable_percentage_of_requests
      record_change('disable_percentage_of_requests', targeting_change(:percentage_requests)) do
        disable_targeting(:percentage_requests)
      end
      true
    end

    def enable_for_date_range(start_date, end_date)
      record_change('enable_for_date_range',
                    targeting_change(:date_range, added: { start: start_date, end: end_date })) do
        enable_targeting(:date_range, { start: start_date, end: end_date })
      end
      true
    end

    def disable_date_range
      record_change('disable_date_range', targeting_change(:date_range)) do
        disable_targeting(:date_range)
      end
      true
    end

    def enable_for_ip_addresses(ip_addresses)
      ips = Array(ip_addresses).map(&:to_s)
      record_change('enable_for_ip_addresses', targeting_change(:ip_address, added: ips)) do
        # ip_address is stored as a flat Array of strings; bypass the generic
        # enable_targeting path whose "array type" branch stringifies the
        # incoming array into a single '["x.y.z"]' entry.
        @targeting[:ip_address] ||= []
        ips.each do |str|
          @targeting[:ip_address] << str unless @targeting[:ip_address].include?(str)
        end
        save_targeting
      end
      true
    end

    def disable_ip_addresses
      record_change('disable_ip_addresses', targeting_change(:ip_address)) do
        disable_targeting(:ip_address)
      end
      true
    end

    def enable_for_custom_attribute(attribute_name, values, operator: :equals)
      change = targeting_change(:custom_attributes,
                                added: { attribute: attribute_name, values: Array(values), operator: operator })
      record_change('enable_for_custom_attribute', change) do
        custom_attrs = targeting[:custom_attributes] || {}
        custom_attrs[attribute_name.to_sym] = { values: Array(values), operator: operator }
        enable_targeting(:custom_attributes, custom_attrs)
      end
      true
    end

    def disable_custom_attribute(attribute_name)
      record_change('disable_custom_attribute', targeting_change(:custom_attributes, removed: attribute_name)) do
        custom_attrs = targeting[:custom_attributes] || {}
        custom_attrs.delete(attribute_name.to_sym)
        if custom_attrs.empty?
          disable_targeting(:custom_attributes)
        else
          enable_targeting(:custom_attributes, custom_attrs)
        end
      end
      true
    end

    def set_variants(variants)
      variants_array = Array(variants).map do |v|
        v.is_a?(FeatureVariant) ? v : FeatureVariant.new(v[:name], v[:value], weight: v[:weight] || 0)
      end
      payload = variants_array.map(&:to_h)

      record_change('set_variants', { variants: payload }) do
        enable_targeting(:variants, payload)

        # Rails 8+ event
        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.variant_set(name, variants: variants_array)
        end
      end

      true
    end

    # Prerequisites are stored with the rest of the feature's state, so a
    # dependency added here is visible to every other process and survives a
    # restart. Adding one already present is a no-op (no audit entry, no
    # version).
    def add_dependency(dependency_name, user_id: nil)
      dep = normalize_dependency_name(dependency_name)
      return true if dependencies.include?(dep)

      record_change('add_dependency', { dependency: { added: dep } }, user_id: user_id) do
        write_dependencies(dependencies + [dep])

        # Rails 8+ event
        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.dependency_added(name, dep)
        end
      end

      true
    end

    def remove_dependency(dependency_name, user_id: nil)
      dep = dependency_name.to_s
      return true unless dependencies.include?(dep)

      record_change('remove_dependency', { dependency: { removed: dep } }, user_id: user_id) do
        write_dependencies(dependencies - [dep])

        # Rails 8+ event
        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.dependency_removed(name, dep)
        end
      end

      true
    end

    # Wholesale prerequisite write: the list IS the new set, [] clears it.
    # Used by import and by callers that manage the whole set at once.
    def replace_dependencies(list, user_id: nil)
      new_list = normalize_dependency_list(list)
      return true if new_list == dependencies

      changes = { dependencies: { from: dependencies.dup, to: new_list.dup } }
      record_change('replace_dependencies', changes, user_id: user_id) do
        write_dependencies(new_list)
      end

      true
    end

    def dependencies
      @dependencies || []
    end

    def get_variant(context = {})
      return nil unless targeting[:variants]

      variants = targeting[:variants]
      return nil if variants.empty?
      return variants.first[:name] if variants.length == 1

      total_weight = variants.sum { |v| v[:weight] || 0 }
      return variants.first[:name] if total_weight.zero?

      # Deterministic assignment: use MD5 hash of feature_name + user_id
      # This ensures the same user always gets the same variant
      user_id = context[:user_id] || context[:user]&.respond_to?(:id) && context[:user].id
      if user_id
        hash = Digest::MD5.hexdigest("#{name}:variant:#{user_id}")
        bucket = hash[0..7].to_i(16) % total_weight
      else
        # No user context — fall back to random (e.g., anonymous requests)
        bucket = rand(total_weight)
      end

      current = 0
      variants.each do |variant|
        current += (variant[:weight] || 0)
        return variant[:name] if bucket < current
      end

      variants.last[:name]
    end

    def get_variant_value(context = {})
      variant_name = get_variant(context)
      return nil unless variant_name

      variant = targeting[:variants]&.find { |v| v[:name] == variant_name }
      variant&.dig(:value)
    end

    def set_value(value, user_id: nil)
      old_value = @stored_value
      validate_value!(value)

      changes = { value: { from: old_value, to: value } }

      record_change('set_value', changes, user_id: user_id) do
        # Bulk write all metadata in a single adapter call instead of 7 separate calls
        data = { 'value' => value, 'type' => type, 'status' => status, 'default_value' => default_value }
        data['description'] = description if description
        data['display_name'] = display_name if display_name
        data['group'] = group if group
        adapter_registry.set_all_data(name, data)

        @stored_value = value
        @stored_value_initialized = true

        # Update registered feature instance if it exists
        if Magick.features.key?(name)
          registered = Magick.features[name]
          registered.instance_variable_set(:@stored_value, value)
          registered.instance_variable_set(:@stored_value_initialized, true)
          registered.instance_variable_set(:@targeting, @targeting.dup) if @targeting
        end

        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.feature_changed(name, changes: changes, user_id: user_id)
        end
      end

      true
    end

    def enable(user_id: nil)
      # Validate the type BEFORE touching anything: a caller that catches this
      # must be able to rely on targeting and the stored value being untouched,
      # in this process and in the backend.
      validate_enableable!

      changes = { value: { from: @stored_value, to: true }, targeting: { cleared: true } }

      record_change('enable', changes, user_id: user_id) do
        # Clear all targeting to enable globally
        @targeting = {}
        save_targeting

        set_value(true, user_id: user_id)

        # Rails 8+ event
        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.feature_enabled_globally(name, user_id: user_id)
        end
      end

      true
    end

    def disable(user_id: nil)
      # Same contract as #enable: nothing is cleared or written unless the whole
      # operation can go through.
      disabled_value = DISABLED_VALUES.fetch(type) do
        raise InvalidFeatureValueError, "Cannot disable feature of type #{type}"
      end
      changes = { value: { from: @stored_value, to: disabled_value }, targeting: { cleared: true } }

      record_change('disable', changes, user_id: user_id) do
        # Clear all targeting to disable globally
        @targeting = {}
        save_targeting

        set_value(disabled_value, user_id: user_id)

        # Ensure registered feature instance also has targeting cleared
        if Magick.features.key?(name)
          registered = Magick.features[name]
          registered.instance_variable_set(:@targeting, {})
        end

        # Rails 8+ event
        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.feature_disabled_globally(name, user_id: user_id)
        end
      end

      true
    end

    def set_status(new_status)
      raise InvalidFeatureValueError, "Invalid status: #{new_status}" unless VALID_STATUSES.include?(new_status.to_sym)

      record_change('set_status', { status: { from: @status, to: new_status.to_sym } }) do
        @status = new_status.to_sym
        adapter_registry.set(name, 'status', status)
      end
      true
    end

    def set_group(group_name)
      new_group = group_name.nil? || group_name.to_s.strip.empty? ? nil : group_name.to_s.strip

      record_change('set_group', { group: { from: @group, to: new_group } }) do
        @group = new_group
        # Clear group from adapter by setting to nil (adapters handle this)
        adapter_registry.set(name, 'group', @group)

        # Update registered feature instance if it exists
        Magick.features[name].instance_variable_set(:@group, @group) if Magick.features.key?(name)
      end

      true
    end

    def delete
      # Snapshot before the wipe so the recorded version captures the state
      # this feature had when it was deleted, not the emptied one.
      snapshot = to_h

      record_change('delete', { deleted: true }, snapshot: snapshot) do
        adapter_registry.delete(name)
        @stored_value = nil
        @stored_value_initialized = false # Reset initialization flag so get_value returns default_value
        @targeting = {}
        # Also remove from Magick.features if registered
        Magick.features.delete(name.to_s)
      end
      true
    end

    # Reload feature state from the shared, authoritative backend (ActiveRecord/
    # Redis), bypassing this process's local in-process memory cache. Used by the
    # Admin UI so a toggle performed on another process/container is reflected
    # immediately, without waiting for Pub/Sub cache invalidation to arrive.
    def reload_from_source!
      adapter_registry.authoritative_get_all_data(name) if adapter_registry.respond_to?(:authoritative_get_all_data)
      reload
    end

    # Reload feature state from adapter (useful when feature is changed externally)
    def reload
      load_from_adapter
      # Update targeting empty cache
      @_targeting_empty = @targeting.empty?
      # Update performance metrics flag (in case it was enabled after feature creation)
      @_perf_metrics_enabled = !Magick.performance_metrics.nil?
      # Update registered feature instance if it exists
      if Magick.features.key?(name)
        registered = Magick.features[name]
        registered.instance_variable_set(:@stored_value, @stored_value)
        registered.instance_variable_set(:@stored_value_initialized, @stored_value_initialized)
        registered.instance_variable_set(:@status, @status)
        registered.instance_variable_set(:@description, @description)
        registered.instance_variable_set(:@display_name, @display_name)
        registered.instance_variable_set(:@group, @group)
        registered.instance_variable_set(:@dependencies, dependencies.dup)
        registered.instance_variable_set(:@targeting, @targeting.dup)
        registered.instance_variable_set(:@_targeting_empty, @_targeting_empty)
        registered.instance_variable_set(:@_perf_metrics_enabled, @_perf_metrics_enabled)
      end
      true
    end

    def to_h
      {
        name: name,
        display_name: display_name,
        group: group,
        type: type,
        status: status,
        value: stored_value,
        default_value: default_value,
        description: description,
        targeting: targeting,
        dependencies: (@dependencies || []).dup,
        variants: variants_for_export
      }
    end

    # Wire-format serializer for control-plane APIs (e.g. the platform's
    # /internal/panel/flags endpoints). The "targeting" key is ALWAYS present
    # ({} = no targeting), array rules are arrays of strings, percentages are
    # floats, and the internal :variants entry never appears inside targeting.
    # Rails-idiomatic: `render json: feature` (or a collection) emits this.
    def as_json(_options = nil)
      {
        'name' => name,
        'display_name' => display_name,
        'group' => group,
        'type' => type.to_s,
        'status' => status.to_s,
        'value' => stored_value,
        'default_value' => default_value,
        'description' => description,
        'targeting' => TargetingPayload.serialize(targeting),
        'dependencies' => (@dependencies || []).map(&:to_s),
        # Variants live inside @targeting under the internal :variants key;
        # both the wire payload and the export read them from there.
        'variants' => TargetingPayload.deep_stringify(variants_for_export)
      }
    end

    # Wholesale, declarative targeting write: the payload IS the new
    # targeting state. Keys absent from it are removed; {} clears all
    # targeting. Accepts wire input leniently (string/symbol keys, plural
    # aliases, scalars for lists, numeric strings) but validates strictly —
    # unknown keys or invalid values raise InvalidTargetingError before any
    # state is touched. The internal :variants entry is not part of the wire
    # payload and survives the replace untouched.
    # Accepts the payload as a positional hash or inline keywords
    # (replace_targeting(user: [3])) — Ruby routes a braceless hash to
    # keywords, so both spellings must land in the same place. Passing
    # nothing raises (via normalize): clearing requires an explicit {}.
    def replace_targeting(payload = nil, user_id: nil, **inline_rules)
      raise ArgumentError, 'pass targeting either as a hash or inline, not both' if payload && inline_rules.any?

      normalized = TargetingPayload.normalize(payload || (inline_rules unless inline_rules.empty?))
      normalized[:variants] = targeting[:variants] if targeting[:variants]

      changes = {
        targeting: {
          from: TargetingPayload.serialize(targeting),
          to: TargetingPayload.serialize(normalized)
        }
      }
      record_change('replace_targeting', changes, user_id: user_id) do
        @targeting = normalized
        persist_targeting

        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.feature_changed(name, changes: changes, user_id: user_id)
        end
      end
      true
    end

    # The canonical list of this feature's variants, as plain hashes.
    # Variants are stored inside @targeting under the internal :variants
    # key (see #set_variants), so that is the only place to read them from.
    # Tolerates the string keys an adapter round-trip can hand back.
    def variants_for_export
      Array(targeting[:variants]).filter_map do |variant|
        next variant.to_h if variant.is_a?(FeatureVariant)
        next unless variant.is_a?(Hash)

        v = variant.transform_keys(&:to_sym)
        { name: v[:name], value: v[:value], weight: v[:weight] }
      end
    end

    # Drops all variants. Absent variants and an empty variants list are
    # different states: an empty list would leave a targeting hash that is
    # no longer empty and so evaluates as "targeted, matched nothing".
    def clear_variants
      return true if targeting[:variants].nil?

      record_change('clear_variants', { variants: [] }) do
        disable_targeting(:variants)

        # Rails 8+ event
        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.variant_set(name, variants: [])
        end
      end

      true
    end

    def save_targeting
      # Records only when called directly (e.g. Admin UI clearing variants);
      # when reached through a wrapping mutator the guard is active and this
      # just persists.
      record_change('update_targeting', { targeting: targeting.dup }) do
        persist_targeting
      end
    end

    # Restore full feature state from a version snapshot (used by
    # Versioning#rollback). Replaces value (including false/empty), status,
    # group, the entire targeting hash and dependencies wholesale.
    def restore_snapshot!(data)
      set_status(data[:status]) if data[:status]
      set_group(data[:group]) if data.key?(:group)

      value = data[:value]
      set_value(cast_value(value)) unless value.nil?

      @targeting = normalize_targeting(data[:targeting])
      save_targeting

      write_dependencies(normalize_dependency_list(data[:dependencies]))
      true
    end

    private

    # Single choke point for change tracking: wraps a public mutator's body,
    # then writes one audit entry and one version snapshot for the operation.
    # A thread-local guard makes nested mutator calls (enable -> set_value)
    # silent, so one logical operation records exactly once, under its real
    # action name. No-op while definitions are being (re)applied at boot.
    def record_change(action, changes = {}, user_id: nil, snapshot: nil)
      if Magick.change_recording_suppressed?
        return block_given? ? yield : true
      end

      result = block_given? ? Magick.suppress_change_recording { yield } : true

      actor = user_id || Magick.current_actor
      Magick.audit_log&.log(name, action, user_id: actor, changes: changes)

      if Magick.versioning_enabled?
        begin
          Magick.versioning&.record_change(self, action: action, created_by: actor, snapshot: snapshot)
        rescue StandardError => e
          warn "Magick: Failed to record version for '#{Magick::LogSafe.sanitize(name)}': #{Magick::LogSafe.sanitize(e.message)}" if defined?(Rails) && Rails.env.development?
        end
      end

      result
    end

    def targeting_change(type, added: nil, removed: nil)
      change = { type: type }
      change[:added] = added unless added.nil?
      change[:removed] = removed unless removed.nil?
      { targeting: change }
    end

    def persist_targeting
      # Normalize on the way out too, so the in-memory hash a writer keeps
      # matches the one a reload produces. Without this the writing process
      # evaluates a flag against a shape no other process ever sees.
      @targeting = normalize_targeting(targeting)

      # Save targeting to adapter (this updates memory synchronously, then Redis/AR)
      # The set method already publishes cache invalidation to other processes via Pub/Sub
      adapter_registry.set(name, 'targeting', targeting)

      # Update the feature in Magick.features if it's registered
      if Magick.features.key?(name)
        Magick.features[name].instance_variable_set(:@targeting, targeting.dup)
        # Update targeting empty cache for performance
        Magick.features[name].instance_variable_set(:@_targeting_empty, targeting.empty?)
      end

      # Update local targeting empty cache for performance
      @_targeting_empty = targeting.empty?

      # NOTE: We don't need to explicitly publish cache invalidation here because:
      # 1. adapter_registry.set already publishes cache invalidation (synchronously for async Redis updates)
      # 2. Publishing twice causes duplicate reloads in other processes
      # 3. The set method handles both sync and async Redis updates correctly
    end

    def stored_value
      return @stored_value if @stored_value_initialized

      load_value_from_adapter
    end

    def load_from_adapter
      # Load ALL keys for this feature in a single adapter call (1 query instead of 6)
      all_data = adapter_registry.get_all_data(name)

      # Parse value
      raw_value = all_data['value']
      unless raw_value.nil?
        loaded_value = cast_value(raw_value)
        @stored_value = loaded_value
        @stored_value_initialized = true
      end

      # Parse status
      status_value = all_data['status']
      @status = status_value ? status_value.to_sym : status

      # Load description from adapter only if not provided in DSL
      unless @description
        description_value = all_data['description']
        @description = description_value if description_value
      end

      # Load display_name from adapter only if not provided in DSL
      unless @display_name
        display_name_value = all_data['display_name']
        @display_name = display_name_value if display_name_value
      end

      # Load group from adapter (can be set via DSL or Admin UI)
      group_value = all_data['group']
      @group = group_value if group_value

      @targeting = normalize_targeting(all_data['targeting'])

      @_loaded_dependencies = stored_dependency_list(all_data[DEPENDENCIES_KEY])
      @_loaded_declared_dependencies = stored_dependency_list(all_data[DECLARED_DEPENDENCIES_KEY])
      @dependencies = effective_dependencies

      # Track what was loaded so save_metadata_if_new can skip unnecessary writes
      @_loaded_description = all_data['description']
      @_loaded_display_name = all_data['display_name']
      @_loaded_group = all_data['group']
    end

    # Canonical in-memory targeting shape: symbol keys at every depth.
    # Adapters hand targeting back JSON-shaped (string keys all the way down),
    # so symbolizing only the top level left variants and custom attributes
    # string-keyed and invisible to their symbol-only readers. This is the one
    # place stored targeting enters the object, and #persist_targeting applies
    # the same pass on the way out, so what a writer holds in memory is
    # exactly what a reader gets back after a reload.
    def normalize_targeting(raw)
      return {} unless raw.is_a?(Hash)

      normalized = TargetingPayload.deep_symbolize(raw)
      normalized[:percentage_users] = normalized[:percentage_users].to_f if normalized[:percentage_users]
      normalized[:percentage_requests] = normalized[:percentage_requests].to_f if normalized[:percentage_requests]
      normalized
    end

    def save_metadata_if_new
      # Only write to adapter if the DSL value differs from what was loaded
      # This avoids unnecessary find_or_initialize_by + save! calls on every boot
      if @description && @description != @_loaded_description
        adapter_registry.set(name, 'description', @description)
      end
      if @display_name && @display_name != @_loaded_display_name
        adapter_registry.set(name, 'display_name', @display_name)
      end
      if @group && @group != @_loaded_group
        adapter_registry.set(name, 'group', @group)
      end
      seed_declared_dependencies
    end

    # Precedence for a feature that declares `dependencies:` in code: stored
    # state wins. A dependency added at runtime on one container must not be
    # erased by every other process that boots with the older declaration, and
    # a process that declares nothing never writes, so it can never erase what
    # another process declared. The one exception is a declaration that CHANGED
    # since it was last recorded — editing `dependencies:` in code has to take
    # effect on the next boot, so it replaces the stored set. Dropping the
    # declaration is NOT a change (an undeclaring process is indistinguishable
    # from a worker that simply registers the feature); remove it with
    # #remove_dependency or #replace_dependencies.
    def effective_dependencies
      if @declared_dependencies && @declared_dependencies != @_loaded_declared_dependencies
        return @declared_dependencies.dup
      end

      (@_loaded_dependencies || @declared_dependencies || []).dup
    end

    def seed_declared_dependencies
      return unless @declared_dependencies
      return if @dependencies == @_loaded_dependencies && @declared_dependencies == @_loaded_declared_dependencies

      write_dependencies(@dependencies, declared: @declared_dependencies)
    end

    # Single write path for the prerequisite set: adapter first (so other
    # processes and the next boot see it), then this process's caches.
    def write_dependencies(list, declared: nil)
      data = { DEPENDENCIES_KEY => list }
      data[DECLARED_DEPENDENCIES_KEY] = declared if declared
      adapter_registry.set_all_data(name, data)

      @dependencies = list
      @_loaded_dependencies = list.dup
      @_loaded_declared_dependencies = declared.dup if declared

      # Magick[:name] hands back a throwaway instance for unregistered names;
      # keep the registered one (if any) in step with the write.
      registered = Magick.features[name]
      registered.instance_variable_set(:@dependencies, list.dup) if registered && !registered.equal?(self)

      list
    end

    def normalize_dependency_list(list)
      Array(list).map { |dep| normalize_dependency_name(dep) }.uniq
    end

    def normalize_dependency_name(dep)
      dep_name = dep.to_s.strip
      raise ArgumentError, 'Magick: dependency name cannot be blank' if dep_name.empty?
      raise ArgumentError, "Magick: feature '#{name}' cannot depend on itself" if dep_name == name

      dep_name
    end

    # Lenient on read (storage may predate the strict write path), strict on
    # write. nil means the key is absent, which is not the same as a stored [].
    def stored_dependency_list(raw)
      return nil unless raw.is_a?(Array)

      raw.map(&:to_s)
    end

    def load_value_from_adapter
      value = adapter_registry.get(name, 'value')
      return nil if value.nil?

      cast_value(value)
    end

    def cast_value(value)
      return nil if value.nil?

      case type
      when :boolean
        [true, 'true', 1].include?(value)
      when :string
        value.to_s
      when :number
        value.to_f
      else
        value
      end
    end

    def check_targeting(context)
      return nil if targeting.empty?

      # Normalize targeting keys (handle both string and symbol keys)
      target = targeting.transform_keys(&:to_sym)

      # If only exclusion keys exist (no inclusion targeting), treat as globally enabled
      inclusion_keys = target.keys.reject { |k| k.to_s.start_with?('excluded_') }
      return true if inclusion_keys.empty?

      # Check user targeting
      if context[:user_id] && target[:user]
        user_list = target[:user].is_a?(Array) ? target[:user] : [target[:user]]
        return true if user_list.include?(context[:user_id].to_s)
      end

      # Check group targeting
      if context[:group] && target[:group]
        group_list = target[:group].is_a?(Array) ? target[:group] : [target[:group]]
        return true if group_list.include?(context[:group].to_s)
      end

      # Check role targeting
      if context[:role] && target[:role]
        role_list = target[:role].is_a?(Array) ? target[:role] : [target[:role]]
        return true if role_list.include?(context[:role].to_s)
      end

      # Check tag targeting
      if context[:tags] && target[:tag]
        context_tags = Array(context[:tags]).map(&:to_s)
        target_tags = target[:tag].is_a?(Array) ? target[:tag].map(&:to_s) : [target[:tag].to_s]
        # Return true if any context tag matches any target tag
        return true if (context_tags & target_tags).any?
      end

      # Check percentage of users (consistent based on user_id)
      if context[:user_id] && target[:percentage_users]
        percentage = target[:percentage_users].to_f
        return true if user_in_percentage?(context[:user_id], percentage)
      end

      # Check percentage of requests (random)
      if target[:percentage_requests]
        percentage = target[:percentage_requests].to_f
        return true if rand(100) < percentage
      end

      nil
    end

    def date_range_active?(date_range_config)
      return true unless date_range_config

      start_date = date_range_config[:start] || date_range_config['start']
      end_date = date_range_config[:end] || date_range_config['end']
      return true unless start_date && end_date

      start_time = start_date.is_a?(String) ? Time.parse(start_date) : start_date
      end_time = end_date.is_a?(String) ? Time.parse(end_date) : end_date
      now = Time.now
      now >= start_time && now <= end_time
    end

    def ip_address_matches?(ip_address)
      return false unless targeting[:ip_address]

      require 'ipaddr'
      ip_list = Array(targeting[:ip_address])
      client_ip = IPAddr.new(ip_address)
      ip_list.any? do |ip_str|
        IPAddr.new(ip_str).include?(client_ip)
      end
    rescue IPAddr::InvalidAddressError, ArgumentError
      false
    end

    def custom_attributes_match?(context, custom_attrs_config)
      return true unless custom_attrs_config

      custom_attrs_config.all? do |attr_name, config|
        context_value = context[attr_name] || context[attr_name.to_s]
        next false if context_value.nil?

        values = Array(config[:values] || config['values'])
        operator = (config[:operator] || config['operator'] || :equals).to_sym

        case operator
        when :equals, :eq
          values.include?(context_value.to_s)
        when :not_equals, :ne
          !values.include?(context_value.to_s)
        when :in
          values.include?(context_value.to_s)
        when :not_in
          !values.include?(context_value.to_s)
        when :greater_than, :gt
          context_value.to_f > values.first.to_f
        when :less_than, :lt
          context_value.to_f < values.first.to_f
        else
          false
        end
      end
    end

    def complex_conditions_match?(context, complex_config)
      return true unless complex_config

      conditions = complex_config[:conditions] || complex_config['conditions'] || []
      operator = (complex_config[:operator] || complex_config['operator'] || :and).to_sym

      evaluate_condition = lambda do |condition|
        condition_type = (condition[:type] || condition['type']).to_sym
        condition_params = condition[:params] || condition['params'] || {}

        case condition_type
        when :user
          user_list = Array(condition_params[:user_ids] || condition_params['user_ids'])
          user_list.include?(context[:user_id]&.to_s)
        when :group
          group_list = Array(condition_params[:groups] || condition_params['groups'])
          group_list.include?(context[:group]&.to_s)
        when :role
          role_list = Array(condition_params[:roles] || condition_params['roles'])
          role_list.include?(context[:role]&.to_s)
        when :custom_attribute
          attr_name = condition_params[:attribute] || condition_params['attribute']
          attr_values = Array(condition_params[:values] || condition_params['values'])
          attr_values.include?(context[attr_name]&.to_s)
        else
          false
        end
      end

      case operator
      when :and, :all
        conditions.all?(&evaluate_condition)
      when :or, :any
        conditions.any?(&evaluate_condition)
      else
        false
      end
    end

    def user_in_percentage?(user_id, percentage)
      hash = Digest::MD5.hexdigest("#{name}:#{user_id}")
      hash_value = hash[0..7].to_i(16)
      (hash_value % 100) < percentage
    end

    def extract_context_from_object(object)
      context = {}

      # Handle hash/struct-like objects
      if object.is_a?(Hash)
        context[:user_id] = object[:user_id] || object['user_id'] || object[:id] || object['id']
        context[:group] = object[:group] || object['group']
        context[:role] = object[:role] || object['role']
        context[:ip_address] = object[:ip_address] || object['ip_address']
        # Extract tags from hash
        tags = object[:tags] || object['tags'] || object[:tag_ids] || object['tag_ids'] || object[:tag_names] || object['tag_names']
        context[:tags] = Array(tags).map(&:to_s) if tags
        # Include all other attributes for custom attribute matching
        object.each do |key, value|
          next if %i[user_id id group role ip_address tags tag_ids tag_names].include?(key.to_sym)
          next if %w[user_id id group role ip_address tags tag_ids tag_names].include?(key.to_s)

          context[key.to_sym] = value
        end
      # Handle ActiveRecord-like objects (respond to methods)
      elsif object.respond_to?(:id) || object.respond_to?(:user_id)
        context[:user_id] = object.respond_to?(:user_id) ? object.user_id : object.id
        context[:group] = object.group if object.respond_to?(:group)
        context[:role] = object.role if object.respond_to?(:role)
        context[:ip_address] = object.ip_address if object.respond_to?(:ip_address)

        # Extract tags from object - try multiple common patterns
        tags = nil
        if object.respond_to?(:tags)
          tags = object.tags
          # Handle ActiveRecord associations - convert to array if needed
          tags = tags.to_a if tags.respond_to?(:to_a) && !tags.is_a?(Array)
        elsif object.respond_to?(:tag_ids)
          tags = object.tag_ids
        elsif object.respond_to?(:tag_names)
          tags = object.tag_names
        end

        # Normalize tags to array of strings
        if tags
          context[:tags] = if tags.respond_to?(:map) && tags.respond_to?(:each)
                             # ActiveRecord association or array
                             tags.map { |tag| tag.respond_to?(:id) ? tag.id.to_s : tag.to_s }
                           else
                             Array(tags).map(&:to_s)
                           end
        end

        # For ActiveRecord objects, include all attributes
        if object.respond_to?(:attributes)
          object.attributes.each do |key, value|
            next if %w[id user_id group role ip_address tags tag_ids tag_names].include?(key.to_s)

            context[key.to_sym] = value
          end
        end
      # Handle simple values (like user_id directly)
      elsif object.respond_to?(:to_i) && object.to_i.to_s == object.to_s
        context[:user_id] = object.to_i
      end

      context
    end

    def dependencies_satisfied?(context)
      deps = dependencies
      return true if deps.empty?

      # Cycle guard: a -> b -> a can never be satisfied, and without this the
      # recursion below dies with SystemStackError, which is not a StandardError
      # and so escapes the fail-safe rescue in #enabled?.
      stack = (Thread.current[:magick_dependency_stack] ||= [])
      if stack.include?(name)
        warn_once_about_dependency(name, "dependency cycle: #{(stack + [name]).join(' -> ')}")
        return false
      end

      stack.push(name)
      begin
        deps.all? { |dep_name| dependency_satisfied?(dep_name.to_s, context) }
      ensure
        stack.pop
      end
    end

    def dependency_satisfied?(dep_name, context)
      prerequisite = Magick.features[dep_name] || prerequisite_from_backend(dep_name)
      return prerequisite.enabled?(context) if prerequisite

      # Genuinely unknown: not registered in this process AND absent from the
      # shared backend. The deliberate default is to treat it as satisfied, so a
      # prerequisite that has not been deployed yet cannot switch off features
      # that are otherwise correctly configured; the dependent feature still
      # obeys its own value and targeting. Set
      # Magick.unknown_dependency_policy = :unsatisfied to fail closed instead.
      # Either way the name is reported once per process, so the condition is
      # never silent.
      satisfied = Magick.unknown_dependency_satisfied?
      warn_once_about_dependency(dep_name,
                                 "unknown prerequisite '#{dep_name}' " \
                                 "(treated as #{satisfied ? 'satisfied' : 'unsatisfied'})")
      satisfied
    end

    # A prerequisite this process never declared can still exist in the shared
    # backend — declared by another service, imported, or created through the
    # Admin UI — so it is evaluated from stored state rather than written off as
    # unknown. Deliberately not memoized: it reads through the registry's memory
    # cache, while a cached instance would go stale (cache invalidation only
    # reloads registered features).
    def prerequisite_from_backend(dep_name)
      return nil if recently_unknown?(dep_name)

      data = adapter_registry.get_all_data(dep_name)
      return remember_unknown_dependency(dep_name) if data.nil? || data.empty?

      options = { type: (data['type'] || :boolean).to_sym }
      options[:default_value] = data['default_value'] unless data['default_value'].nil?
      begin
        Feature.new(dep_name, adapter_registry, **options)
      rescue StandardError
        # Stored state we cannot build a feature from (bad type/default) is no
        # more usable than a missing one, and re-probing it on every call would
        # be pure cost.
        remember_unknown_dependency(dep_name)
      end
    end

    def remember_unknown_dependency(dep_name)
      (@_unknown_dependencies ||= {})[dep_name] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      nil
    end

    def recently_unknown?(dep_name)
      last_seen = @_unknown_dependencies && @_unknown_dependencies[dep_name]
      return false unless last_seen

      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - last_seen) < UNKNOWN_DEPENDENCY_RECHECK_SECONDS
    end

    def warn_once_about_dependency(key, message)
      @_warned_dependencies ||= {}
      return if @_warned_dependencies[key]

      @_warned_dependencies[key] = true
      warn "Magick: feature '#{Magick::LogSafe.sanitize(name)}': #{Magick::LogSafe.sanitize(message)}"
    end

    def excluded?(context)
      target = targeting.transform_keys(&:to_sym)

      # Check excluded users
      if context[:user_id] && target[:excluded_users]
        excluded_list = target[:excluded_users].is_a?(Array) ? target[:excluded_users] : [target[:excluded_users]]
        return true if excluded_list.include?(context[:user_id].to_s)
      end

      # Check excluded groups
      if context[:group] && target[:excluded_groups]
        excluded_list = target[:excluded_groups].is_a?(Array) ? target[:excluded_groups] : [target[:excluded_groups]]
        return true if excluded_list.include?(context[:group].to_s)
      end

      # Check excluded roles
      if context[:role] && target[:excluded_roles]
        excluded_list = target[:excluded_roles].is_a?(Array) ? target[:excluded_roles] : [target[:excluded_roles]]
        return true if excluded_list.include?(context[:role].to_s)
      end

      # Check excluded tags
      if context[:tags] && target[:excluded_tags]
        context_tags = Array(context[:tags]).map(&:to_s)
        excluded_tags = target[:excluded_tags].is_a?(Array) ? target[:excluded_tags].map(&:to_s) : [target[:excluded_tags].to_s]
        return true if (context_tags & excluded_tags).any?
      end

      # Check excluded IP addresses
      if context[:ip_address] && target[:excluded_ip_addresses]
        begin
          require 'ipaddr'
          excluded_ips = Array(target[:excluded_ip_addresses])
          client_ip = IPAddr.new(context[:ip_address])
          return true if excluded_ips.any? { |ip_str| IPAddr.new(ip_str).include?(client_ip) }
        rescue IPAddr::InvalidAddressError, ArgumentError
          # Invalid IP, not excluded
        end
      end

      false
    end

    def enable_targeting(type, value)
      case type
      when :date_range, :custom_attributes, :complex_conditions, :variants, :excluded_ip_addresses
        # These types store structured data directly (Hash or Array of Hashes)
        @targeting[type] = value
      when :percentage_users, :percentage_requests
        # Numeric types store a single value
        @targeting[type] = value.to_f
      else
        # Array-based types (user, group, role, tag, ip_address)
        @targeting[type] ||= []
        str_value = value.to_s
        @targeting[type] << str_value unless @targeting[type].include?(str_value)
      end
      save_targeting

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.targeting_added(name, targeting_type: type, targeting_value: value)
      end

      true
    end

    def disable_targeting(type, value = nil)
      if value.nil?
        @targeting.delete(type)
      else
        @targeting[type]&.delete(value.to_s)
      end
      save_targeting

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.targeting_removed(name, targeting_type: type, targeting_value: value)
      end

      true
    end

    def default_for_type
      case type
      when :boolean
        false
      when :string
        ''
      when :number
        0
      else
        false
      end
    end

    def validate_type!
      return if VALID_TYPES.include?(type)

      raise InvalidFeatureTypeError, "Invalid feature type: #{type}. Valid types are: #{VALID_TYPES.join(', ')}"
    end

    def validate_default_value!
      case type
      when :boolean
        unless [true, false].include?(default_value)
          raise InvalidFeatureValueError, 'Default value must be boolean for type :boolean'
        end
      when :string
        unless default_value.is_a?(String)
          raise InvalidFeatureValueError,
                'Default value must be a string for type :string'
        end
      when :number
        unless default_value.is_a?(Numeric)
          raise InvalidFeatureValueError,
                'Default value must be numeric for type :number'
        end
      end
    end

    # Only a boolean feature has a meaningful "on": a string or number feature
    # carries a value, so enabling it is meaningless. Called before #enable
    # touches any state, so the raise leaves the feature exactly as it was.
    def validate_enableable!
      case type
      when :boolean
        nil
      when :string
        raise InvalidFeatureValueError, 'Cannot enable string feature. Use set_value instead.'
      when :number
        raise InvalidFeatureValueError, 'Cannot enable number feature. Use set_value instead.'
      else
        raise InvalidFeatureValueError, "Cannot enable feature of type #{type}"
      end
    end

    def validate_value!(value)
      case type
      when :boolean
        raise InvalidFeatureValueError, 'Value must be boolean for type :boolean' unless [true, false].include?(value)
      when :string
        raise InvalidFeatureValueError, 'Value must be a string for type :string' unless value.is_a?(String)
      when :number
        raise InvalidFeatureValueError, 'Value must be numeric for type :number' unless value.is_a?(Numeric)
      end
    end
  end
end
