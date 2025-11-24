# frozen_string_literal: true

require 'digest'
require_relative '../magick/feature_variant'

module Magick
  class Feature
    VALID_TYPES = %i[boolean string number].freeze
    VALID_STATUSES = %i[active inactive deprecated].freeze

    attr_reader :name, :type, :status, :default_value, :description, :display_name, :adapter_registry

    def initialize(name, adapter_registry, **options)
      @name = name.to_s
      @adapter_registry = adapter_registry
      @type = (options[:type] || :boolean).to_sym
      @status = (options[:status] || :active).to_sym
      @default_value = options.fetch(:default_value, default_for_type)
      @description = options[:description]
      @display_name = options[:name] || options[:display_name]
      @targeting = {}
      @dependencies = options[:dependencies] ? Array(options[:dependencies]) : []
      @stored_value_initialized = false # Track if @stored_value has been explicitly set

      validate_type!
      validate_default_value!
      load_from_adapter
      # Save description and display_name to adapter if they were provided and not already in adapter
      save_metadata_if_new
    end

    def enabled?(context = {})
      # Track usage if metrics available
      start_time = Time.now if Magick.performance_metrics

      result = check_enabled(context)

      if Magick.performance_metrics
        duration = (Time.now - start_time) * 1000 # milliseconds
        Magick.performance_metrics.record(name, 'enabled?', duration, success: true)
      end

      # Rails 8+ events for enabled/disabled
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        if result
          Magick::Rails::Events.feature_enabled(name, context: context)
        else
          Magick::Rails::Events.feature_disabled(name, context: context)
        end
      end

      # Warn if deprecated
      if status == :deprecated && result && !context[:allow_deprecated]
        warn "DEPRECATED: Feature '#{name}' is deprecated and will be removed." if Magick.warn_on_deprecated

        # Rails 8+ event for deprecation warning
        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.deprecated_warning(name)
        end
      end

      result
    rescue StandardError => e
      if Magick.performance_metrics
        duration = (Time.now - start_time) * 1000
        Magick.performance_metrics.record(name, 'enabled?', duration, success: false)
      end
      # Return false on any error (fail-safe)
      warn "Magick: Error checking feature '#{name}': #{e.message}" if defined?(Rails) && Rails.env.development?
      false
    end

    def check_enabled(context = {})
      return false if status == :inactive
      return false if status == :deprecated && !context[:allow_deprecated]

      # NOTE: We don't check dependencies here because:
      # - Main features can be enabled independently
      # - Dependencies are only prevented from being enabled if the main feature is disabled
      # - The dependency check is handled in the enable() method, not in enabled?()

      # Check date/time range targeting
      return false if targeting[:date_range] && !date_range_active?(targeting[:date_range])

      # Check IP address targeting
      return false if targeting[:ip_address] && context[:ip_address] && !ip_address_matches?(context[:ip_address])

      # Check custom attributes
      return false if targeting[:custom_attributes] && !custom_attributes_match?(context, targeting[:custom_attributes])

      # Check complex conditions
      if targeting[:complex_conditions] && !complex_conditions_match?(context, targeting[:complex_conditions])
        return false
      end

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
      warn "Magick: Error in check_enabled for '#{name}': #{e.message}" if defined?(Rails) && Rails.env.development?
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
      # Check targeting rules first
      targeting_result = check_targeting(context)
      return targeting_result unless targeting_result.nil?

      # Use instance variable if it has been set (check using defined? to handle nil vs uninitialized)
      # We use a special check: if @stored_value was explicitly set (even to false), use it
      # We track this by checking if @stored_value_initialized flag is set
      return @stored_value if defined?(@stored_value_initialized) && @stored_value_initialized

      # Load from adapter if instance variable hasn't been initialized
      loaded_value = load_value_from_adapter
      if loaded_value.nil?
        # Value not found in adapter, use default
        default_value
      else
        # Value found in adapter, use it and mark as initialized
        @stored_value = loaded_value
        @stored_value_initialized = true
        loaded_value
      end
    rescue StandardError => e
      # Return default value on error (fail-safe)
      warn "Magick: Error in get_value for '#{name}': #{e.message}" if defined?(Rails) && Rails.env.development?
      default_value
    end

    def enable_for_user(user_id)
      enable_targeting(:user, user_id)
      true
    end

    def disable_for_user(user_id)
      disable_targeting(:user, user_id)
      true
    end

    def enable_for_group(group_name)
      enable_targeting(:group, group_name)
      true
    end

    def disable_for_group(group_name)
      disable_targeting(:group, group_name)
      true
    end

    def enable_for_role(role_name)
      enable_targeting(:role, role_name)
      true
    end

    def disable_for_role(role_name)
      disable_targeting(:role, role_name)
      true
    end

    def enable_percentage_of_users(percentage)
      @targeting[:percentage_users] = percentage.to_f
      save_targeting

      # Update registered feature instance if it exists
      Magick.features[name].instance_variable_set(:@targeting, @targeting.dup) if Magick.features.key?(name)

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.targeting_added(name, targeting_type: :percentage_users, targeting_value: percentage)
      end

      true
    end

    def disable_percentage_of_users
      disable_targeting(:percentage_users)
      true
    end

    def enable_percentage_of_requests(percentage)
      @targeting[:percentage_requests] = percentage.to_f
      save_targeting

      # Update registered feature instance if it exists
      Magick.features[name].instance_variable_set(:@targeting, @targeting.dup) if Magick.features.key?(name)

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.targeting_added(name, targeting_type: :percentage_requests, targeting_value: percentage)
      end

      true
    end

    def disable_percentage_of_requests
      disable_targeting(:percentage_requests)
      true
    end

    def enable_for_date_range(start_date, end_date)
      enable_targeting(:date_range, { start: start_date, end: end_date })
      true
    end

    def disable_date_range
      disable_targeting(:date_range)
      true
    end

    def enable_for_ip_addresses(ip_addresses)
      enable_targeting(:ip_address, Array(ip_addresses))
      true
    end

    def disable_ip_addresses
      disable_targeting(:ip_address)
      true
    end

    def enable_for_custom_attribute(attribute_name, values, operator: :equals)
      custom_attrs = targeting[:custom_attributes] || {}
      custom_attrs[attribute_name.to_sym] = { values: Array(values), operator: operator }
      enable_targeting(:custom_attributes, custom_attrs)
      true
    end

    def disable_custom_attribute(attribute_name)
      custom_attrs = targeting[:custom_attributes] || {}
      custom_attrs.delete(attribute_name.to_sym)
      if custom_attrs.empty?
        disable_targeting(:custom_attributes)
      else
        enable_targeting(:custom_attributes, custom_attrs)
      end
      true
    end

    def set_variants(variants)
      variants_array = Array(variants).map do |v|
        v.is_a?(FeatureVariant) ? v : FeatureVariant.new(v[:name], v[:value], weight: v[:weight] || 0)
      end
      enable_targeting(:variants, variants_array.map(&:to_h))

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.variant_set(name, variants: variants_array)
      end

      true
    end

    def add_dependency(dependency_name)
      @dependencies ||= []
      @dependencies << dependency_name.to_s unless @dependencies.include?(dependency_name.to_s)

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.dependency_added(name, dependency_name)
      end

      true
    end

    def remove_dependency(dependency_name)
      @dependencies&.delete(dependency_name.to_s)

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.dependency_removed(name, dependency_name)
      end

      true
    end

    def dependencies
      @dependencies || []
    end

    def get_variant(context = {})
      return nil unless targeting[:variants]

      variants = targeting[:variants]
      selected_variant = if variants.length == 1
                           variants.first[:name]
                         else
                           # Weighted random selection
                           total_weight = variants.sum { |v| v[:weight] || 0 }
                           if total_weight.zero?
                             variants.first[:name]
                           else
                             random = rand(total_weight)
                             current = 0
                             selected = nil
                             variants.each do |variant|
                               current += variant[:weight] || 0
                               if random < current
                                 selected = variant[:name]
                                 break
                               end
                             end
                             selected || variants.first[:name]
                           end
                         end

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.variant_selected(name, variant_name: selected_variant, context: context)
      end

      selected_variant
    end

    def set_value(value, user_id: nil)
      old_value = @stored_value
      validate_value!(value)
      adapter_registry.set(name, 'value', value)
      adapter_registry.set(name, 'type', type)
      adapter_registry.set(name, 'status', status)
      adapter_registry.set(name, 'default_value', default_value)
      adapter_registry.set(name, 'description', description) if description
      adapter_registry.set(name, 'display_name', display_name) if display_name
      @stored_value = value
      @stored_value_initialized = true # Mark as initialized

      # Update registered feature instance if it exists
      if Magick.features.key?(name)
        registered = Magick.features[name]
        registered.instance_variable_set(:@stored_value, value)
        registered.instance_variable_set(:@stored_value_initialized, true)
        registered.instance_variable_set(:@targeting, @targeting.dup) if @targeting
      end

      changes = { value: { from: old_value, to: value } }

      # Audit log
      Magick.audit_log&.log(
        name,
        'set_value',
        user_id: user_id,
        changes: changes
      )

      # Rails 8+ events
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.feature_changed(name, changes: changes, user_id: user_id)
        Magick::Rails::Events.audit_logged(name, action: 'set_value', user_id: user_id, changes: changes)
      end

      true
    end

    def enable(user_id: nil)
      # Check if this feature is a dependency of any disabled features
      # If a main feature that depends on this feature is disabled, prevent enabling this dependency
      # Dependencies cannot be enabled until the main feature is enabled
      dependent_features = find_dependent_features
      disabled_dependents = dependent_features.select do |dep_feature_name|
        dep_feature = Magick.features[dep_feature_name.to_s] || Magick[dep_feature_name]
        # Check if the dependent feature (main feature) is disabled
        dep_feature && !dep_feature.enabled?
      end

      unless disabled_dependents.empty?
        # Return false if any main feature that depends on this feature is disabled
        # This prevents enabling a dependency when the main feature is disabled
        return false
      end

      # Clear all targeting to enable globally
      @targeting = {}
      save_targeting

      case type
      when :boolean
        set_value(true, user_id: user_id)
      when :string
        raise InvalidFeatureValueError, 'Cannot enable string feature. Use set_value instead.'
      when :number
        raise InvalidFeatureValueError, 'Cannot enable number feature. Use set_value instead.'
      else
        raise InvalidFeatureValueError, "Cannot enable feature of type #{type}"
      end

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.feature_enabled_globally(name, user_id: user_id)
      end

      true
    end

    def disable(user_id: nil)
      # Clear all targeting to disable globally
      @targeting = {}
      save_targeting

      case type
      when :boolean
        set_value(false, user_id: user_id)
      when :string
        set_value('', user_id: user_id)
      when :number
        set_value(0, user_id: user_id)
      else
        raise InvalidFeatureValueError, "Cannot disable feature of type #{type}"
      end

      # Ensure registered feature instance also has targeting cleared
      if Magick.features.key?(name)
        registered = Magick.features[name]
        registered.instance_variable_set(:@targeting, {})
      end

      # Cascade disable: disable all features that depend on this one
      disable_dependent_features(user_id: user_id)

      # Rails 8+ event
      if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
        Magick::Rails::Events.feature_disabled_globally(name, user_id: user_id)
      end

      true
    end

    def set_status(new_status)
      raise InvalidFeatureValueError, "Invalid status: #{new_status}" unless VALID_STATUSES.include?(new_status.to_sym)

      @status = new_status.to_sym
      adapter_registry.set(name, 'status', status)
      true
    end

    def delete
      adapter_registry.delete(name)
      @stored_value = nil
      @stored_value_initialized = false # Reset initialization flag so get_value returns default_value
      @targeting = {}
      # Also remove from Magick.features if registered
      Magick.features.delete(name.to_s)
      true
    end

    # Reload feature state from adapter (useful when feature is changed externally)
    def reload
      load_from_adapter
      # Update registered feature instance if it exists
      if Magick.features.key?(name)
        registered = Magick.features[name]
        registered.instance_variable_set(:@stored_value, @stored_value)
        registered.instance_variable_set(:@stored_value_initialized, @stored_value_initialized)
        registered.instance_variable_set(:@status, @status)
        registered.instance_variable_set(:@description, @description)
        registered.instance_variable_set(:@display_name, @display_name)
        registered.instance_variable_set(:@targeting, @targeting.dup)
      end
      true
    end

    def to_h
      {
        name: name,
        display_name: display_name,
        type: type,
        status: status,
        value: stored_value,
        default_value: default_value,
        description: description,
        targeting: targeting
      }
    end

    private

    attr_reader :targeting

    def stored_value
      # Always go through adapter to check for cross-process updates via version checking
      # The adapter registry will check Redis version and invalidate memory cache if stale
      load_value_from_adapter
    end

    def load_from_adapter
      # Load value from adapter
      loaded_value = load_value_from_adapter
      # Set @stored_value if we got a value from adapter (can be false, true, '', 0, etc.)
      # Only set if loaded_value is not nil (nil means not found in adapter)
      unless loaded_value.nil?
        @stored_value = loaded_value
        @stored_value_initialized = true
      end

      status_value = adapter_registry.get(name, 'status')
      @status = status_value ? status_value.to_sym : status

      # Load description from adapter only if not provided in DSL
      # DSL (features.rb) is the source of truth, so don't override DSL values
      unless @description
        description_value = adapter_registry.get(name, 'description')
        @description = description_value if description_value
      end

      # Load display_name from adapter only if not provided in DSL
      # DSL (features.rb) is the source of truth, so don't override DSL values
      unless @display_name
        display_name_value = adapter_registry.get(name, 'display_name')
        @display_name = display_name_value if display_name_value
      end

      targeting_value = adapter_registry.get(name, 'targeting')
      if targeting_value.is_a?(Hash)
        # Normalize keys to symbols and handle nested structures
        @targeting = targeting_value.transform_keys(&:to_sym)
        # Handle percentage_users and percentage_requests which might be stored as numbers
        @targeting[:percentage_users] = @targeting[:percentage_users].to_f if @targeting[:percentage_users]
        @targeting[:percentage_requests] = @targeting[:percentage_requests].to_f if @targeting[:percentage_requests]
      else
        @targeting = {}
      end
    end

    def save_metadata_if_new
      # Always save description and display_name from DSL to adapter
      # The features.rb file is the source of truth for metadata
      # This ensures metadata is always up-to-date even if feature already exists
      adapter_registry.set(name, 'description', @description) if @description
      return unless @display_name

      adapter_registry.set(name, 'display_name', @display_name)
    end

    def load_value_from_adapter
      value = adapter_registry.get(name, 'value')
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
    rescue IPAddr::InvalidAddressError
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

      results = conditions.map do |condition|
        # Each condition is a hash with type and params
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
        results.all?
      when :or, :any
        results.any?
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
        # Include all other attributes for custom attribute matching
        object.each do |key, value|
          next if %i[user_id id group role ip_address].include?(key.to_sym)
          next if %w[user_id id group role ip_address].include?(key.to_s)

          context[key.to_sym] = value
        end
      # Handle ActiveRecord-like objects (respond to methods)
      elsif object.respond_to?(:id) || object.respond_to?(:user_id)
        context[:user_id] = object.respond_to?(:user_id) ? object.user_id : object.id
        context[:group] = object.group if object.respond_to?(:group)
        context[:role] = object.role if object.respond_to?(:role)
        context[:ip_address] = object.ip_address if object.respond_to?(:ip_address)

        # For ActiveRecord objects, include all attributes
        if object.respond_to?(:attributes)
          object.attributes.each do |key, value|
            next if %w[id user_id group role ip_address].include?(key.to_s)

            context[key.to_sym] = value
          end
        end
      # Handle simple values (like user_id directly)
      elsif object.respond_to?(:to_i) && object.to_i.to_s == object.to_s
        context[:user_id] = object.to_i
      end

      context
    end

    def disable_dependent_features(user_id: nil)
      # Find all features that depend on this feature
      dependent_features = find_dependent_features

      # Disable each dependent feature by setting value directly (avoid recursion)
      dependent_features.each do |dep_feature_name|
        dep_feature = Magick.features[dep_feature_name.to_s] || Magick[dep_feature_name]
        next unless dep_feature

        # Set value directly to avoid recursive disable calls
        # Clear targeting and set value to false/empty/0 based on type
        dep_feature.instance_variable_set(:@targeting, {})
        dep_feature.save_targeting

        case dep_feature.type
        when :boolean
          dep_feature.set_value(false, user_id: user_id)
        when :string
          dep_feature.set_value('', user_id: user_id)
        when :number
          dep_feature.set_value(0, user_id: user_id)
        end

        # Rails 8+ event
        if defined?(Magick::Rails::Events) && Magick::Rails::Events.rails8?
          Magick::Rails::Events.feature_disabled_globally(dep_feature_name, user_id: user_id)
        end
      end
    end

    def find_dependent_features
      # Find all features that have this feature in their dependencies
      dependent_features = []
      Magick.features.each do |_name, feature|
        feature_deps = feature.instance_variable_get(:@dependencies) || []
        dependent_features << feature.name if feature_deps.include?(name.to_s) || feature_deps.include?(name.to_sym)
      end
      dependent_features
    end

    def enable_targeting(type, value)
      @targeting[type] ||= []
      @targeting[type] << value.to_s unless @targeting[type].include?(value.to_s)
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

    def save_targeting
      # Save targeting to adapter (this triggers cache invalidation via Pub/Sub)
      adapter_registry.set(name, 'targeting', targeting)

      # Update the feature in Magick.features if it's registered
      return unless Magick.features.key?(name)

      Magick.features[name].instance_variable_set(:@targeting, targeting.dup)

      # Explicitly trigger cache invalidation for targeting updates
      # Targeting changes affect enabled? checks, so we need immediate cache invalidation
      # even if async updates are enabled
      return unless adapter_registry.respond_to?(:invalidate_cache)

      adapter_registry.invalidate_cache(name)
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
