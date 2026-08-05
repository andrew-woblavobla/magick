# frozen_string_literal: true

require 'ipaddr'
require 'time'

module Magick
  # Translates between the internal targeting hash and the wire-format
  # targeting payload exchanged with control planes (panel contract):
  #
  #   GET  -> Feature#as_json emits `serialize(targeting)` — string keys,
  #           arrays of strings, floats; the "targeting" key is always
  #           present ({} = no targeting).
  #   PATCH -> Feature#replace_targeting runs the inbound payload through
  #           `normalize` — lenient about aliases/scalars/key types, strict
  #           about vocabulary and values (all-or-nothing).
  #
  # The internal-only :variants key never crosses the wire in either
  # direction: `serialize` drops it, `normalize` rejects it.
  module TargetingPayload
    # Inclusion keys are singular, exclusion keys plural — mirrors the
    # internal @targeting layout, which is also the persisted layout.
    ARRAY_KEYS = %i[
      user group role tag ip_address
      excluded_users excluded_groups excluded_roles excluded_tags excluded_ip_addresses
    ].freeze
    PERCENTAGE_KEYS = %i[percentage_users percentage_requests].freeze
    STRUCTURED_KEYS = %i[date_range custom_attributes complex_conditions].freeze
    CANONICAL_KEYS = (ARRAY_KEYS + PERCENTAGE_KEYS + STRUCTURED_KEYS).freeze

    # Plural spellings accepted on input for parity with Magick.import.
    ALIASES = {
      users: :user,
      groups: :group,
      roles: :role,
      tags: :tag,
      ip_addresses: :ip_address
    }.freeze

    IP_KEYS = %i[ip_address excluded_ip_addresses].freeze

    CUSTOM_ATTRIBUTE_OPERATORS = %i[equals eq not_equals ne in not_in greater_than gt less_than lt].freeze
    COMPLEX_OPERATORS = %i[and or].freeze
    COMPLEX_CONDITION_TYPES = %i[user group role custom_attribute].freeze

    module_function

    # Wire payload -> canonical internal targeting hash. Raises
    # InvalidTargetingError on the first problem, before any state is
    # touched, so callers get all-or-nothing semantics for free.
    def normalize(payload)
      raise InvalidTargetingError, "targeting must be a Hash, got #{payload.class}" unless payload.is_a?(Hash)

      normalized = {}
      payload.each do |raw_key, raw_value|
        key = canonical_key(raw_key)
        raise InvalidTargetingError, "conflicting targeting keys resolve to '#{key}'" if normalized.key?(key)
        next if raw_value.nil? # nil = remove the rule, same as omitting the key

        value = normalize_value(key, raw_value)
        normalized[key] = value unless value.nil?
      end
      normalized
    end

    # Internal targeting hash -> wire payload. Never raises: the read path
    # must serialize whatever historical state an adapter hands back.
    def serialize(targeting)
      return {} unless targeting.is_a?(Hash)

      targeting.each_with_object({}) do |(key, value), wire|
        key = key.to_sym
        next if key == :variants # internal-only, managed via set_variants

        wire[key.to_s] =
          if ARRAY_KEYS.include?(key)
            Array(value).map(&:to_s)
          elsif PERCENTAGE_KEYS.include?(key)
            value.to_f
          elsif key == :date_range
            serialize_date_range(value)
          else
            deep_stringify(value)
          end
      end
    end

    def canonical_key(raw_key)
      key = raw_key.to_sym
      key = ALIASES.fetch(key, key)
      if key == :variants
        raise InvalidTargetingError, 'variants are not part of the targeting payload (use set_variants)'
      end
      raise InvalidTargetingError, "unknown targeting key: '#{raw_key}'" unless CANONICAL_KEYS.include?(key)

      key
    end

    def normalize_value(key, value)
      if ARRAY_KEYS.include?(key)
        normalize_array(key, value)
      elsif PERCENTAGE_KEYS.include?(key)
        normalize_percentage(key, value)
      elsif key == :date_range
        normalize_date_range(value)
      elsif key == :custom_attributes
        normalize_custom_attributes(value)
      else # :complex_conditions
        normalize_complex_conditions(value)
      end
    end

    # Scalars are accepted as one-element lists; empty lists mean "no rule"
    # and collapse to key removal, keeping {} the only spelling of
    # "no targeting".
    def normalize_array(key, value)
      values = (value.is_a?(Array) ? value : [value]).compact.map { |v| v.to_s.strip }.reject(&:empty?).uniq
      return nil if values.empty?

      validate_ip_list!(key, values) if IP_KEYS.include?(key)
      values
    end

    def validate_ip_list!(key, values)
      values.each do |ip|
        IPAddr.new(ip)
      rescue ArgumentError # includes IPAddr::Error
        raise InvalidTargetingError, "invalid IP address or CIDR range in '#{key}': '#{ip}'"
      end
    end

    def normalize_percentage(key, value)
      percentage = begin
        Float(value)
      rescue ArgumentError, TypeError
        raise InvalidTargetingError, "'#{key}' must be a number, got #{value.inspect}"
      end
      unless percentage.positive? && percentage <= 100
        raise InvalidTargetingError, "'#{key}' must be within (0, 100], got #{percentage}"
      end

      percentage
    end

    def normalize_date_range(value)
      raise InvalidTargetingError, "'date_range' must be a Hash with start and end" unless value.is_a?(Hash)

      start_value = value[:start] || value['start']
      end_value = value[:end] || value['end']
      raise InvalidTargetingError, "'date_range' requires both start and end" unless start_value && end_value

      { start: parse_date_bound(start_value), end: parse_date_bound(end_value) }
    end

    def parse_date_bound(value)
      return value unless value.is_a?(String)

      Time.parse(value)
      value
    rescue ArgumentError
      raise InvalidTargetingError, "'date_range' bound is not a parseable time: '#{value}'"
    end

    def normalize_custom_attributes(value)
      raise InvalidTargetingError, "'custom_attributes' must be a Hash" unless value.is_a?(Hash)

      value.each_with_object({}) do |(attribute, rule), result|
        raise InvalidTargetingError, "rule for custom attribute '#{attribute}' must be a Hash" unless rule.is_a?(Hash)

        values = Array(rule[:values] || rule['values']).compact.map(&:to_s).reject(&:empty?)
        raise InvalidTargetingError, "custom attribute '#{attribute}' requires values" if values.empty?

        operator = (rule[:operator] || rule['operator'] || :equals).to_sym
        unless CUSTOM_ATTRIBUTE_OPERATORS.include?(operator)
          raise InvalidTargetingError, "unknown operator '#{operator}' for custom attribute '#{attribute}'"
        end

        result[attribute.to_sym] = { values: values, operator: operator }
      end
    end

    def normalize_complex_conditions(value)
      raise InvalidTargetingError, "'complex_conditions' must be a Hash" unless value.is_a?(Hash)

      operator = (value[:operator] || value['operator'] || :and).to_sym
      unless COMPLEX_OPERATORS.include?(operator)
        raise InvalidTargetingError, "'complex_conditions' operator must be and/or, got '#{operator}'"
      end

      conditions = value[:conditions] || value['conditions']
      raise InvalidTargetingError, "'complex_conditions' requires a conditions Array" unless conditions.is_a?(Array)

      { operator: operator, conditions: conditions.map { |c| normalize_complex_condition(c) } }
    end

    def normalize_complex_condition(condition)
      raise InvalidTargetingError, 'each complex condition must be a Hash' unless condition.is_a?(Hash)

      type = (condition[:type] || condition['type']).to_s.to_sym
      unless COMPLEX_CONDITION_TYPES.include?(type)
        raise InvalidTargetingError, "unknown complex condition type: '#{type}'"
      end

      params = condition[:params] || condition['params'] || {}
      raise InvalidTargetingError, "params for complex condition '#{type}' must be a Hash" unless params.is_a?(Hash)

      { type: type, params: params.transform_keys(&:to_sym) }
    end

    def serialize_date_range(value)
      return deep_stringify(value) unless value.is_a?(Hash)

      start_value = value[:start] || value['start']
      end_value = value[:end] || value['end']
      { 'start' => serialize_time(start_value), 'end' => serialize_time(end_value) }
    end

    def serialize_time(value)
      return value if value.nil? || value.is_a?(String)
      return value.iso8601 if value.respond_to?(:iso8601)

      value.to_s
    end

    def deep_stringify(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
      when Array
        value.map { |v| deep_stringify(v) }
      when Symbol
        value.to_s
      else
        value
      end
    end
  end
end
