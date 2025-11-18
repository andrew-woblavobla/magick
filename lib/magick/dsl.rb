# frozen_string_literal: true

module Magick
  module DSL
    # Feature definition DSL methods
    def feature(name, **options)
      Magick.register_feature(name, **options)
    end

    def boolean_feature(name, default: false, **options)
      Magick.register_feature(name, type: :boolean, default_value: default, **options)
    end

    def string_feature(name, default: '', **options)
      Magick.register_feature(name, type: :string, default_value: default, **options)
    end

    def number_feature(name, default: 0, **options)
      Magick.register_feature(name, type: :number, default_value: default, **options)
    end

    # Targeting DSL methods
    def enable_for_user(feature_name, user_id)
      Magick[feature_name].enable_for_user(user_id)
    end

    def enable_for_group(feature_name, group_name)
      Magick[feature_name].enable_for_group(group_name)
    end

    def enable_for_role(feature_name, role_name)
      Magick[feature_name].enable_for_role(role_name)
    end

    def enable_percentage(feature_name, percentage, type: :users)
      feature = Magick[feature_name]
      case type
      when :users
        feature.enable_percentage_of_users(percentage)
      when :requests
        feature.enable_percentage_of_requests(percentage)
      end
    end

    def enable_for_date_range(feature_name, start_date, end_date)
      Magick[feature_name].enable_for_date_range(start_date, end_date)
    end

    def enable_for_ip_addresses(feature_name, *ip_addresses)
      Magick[feature_name].enable_for_ip_addresses(ip_addresses)
    end

    def enable_for_custom_attribute(feature_name, attribute_name, values, operator: :equals)
      Magick[feature_name].enable_for_custom_attribute(attribute_name, values, operator: operator)
    end

    def set_variants(feature_name, variants)
      Magick[feature_name].set_variants(variants)
    end

    def add_dependency(feature_name, dependency_name)
      Magick[feature_name].add_dependency(dependency_name)
    end
  end
end

# Make DSL methods available at top level for config/features.rb and config/initializers/features.rb
# Include into Object so methods are available as instance methods on main (top-level context)
Object.class_eval do
  include Magick::DSL unless included_modules.include?(Magick::DSL)
end
