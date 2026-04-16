# frozen_string_literal: true

module Magick
  module AdminUI
    module Helpers
      def self.feature_status_badge(status)
        klass = case status.to_sym
                when :active then 'badge badge-success'
                when :deprecated then 'badge badge-warning'
                when :inactive then 'badge badge-danger'
                else 'badge'
                end
        label = case status.to_sym
                when :active then 'Active'
                when :deprecated then 'Deprecated'
                when :inactive then 'Inactive'
                else 'Unknown'
                end

        if defined?(ActionController::Base)
          ActionController::Base.helpers.content_tag(:span, label, class: klass)
        else
          # Fallback when Rails is not present. Label is a whitelisted literal.
          "<span class=\"#{klass}\">#{label}</span>"
        end
      end

      def self.feature_type_label(type)
        case type.to_sym
        when :boolean then 'Boolean'
        when :string then 'String'
        when :number then 'Number'
        else type.to_s.capitalize
        end
      end
    end
  end
end
