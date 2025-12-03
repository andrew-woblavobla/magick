# frozen_string_literal: true

module Magick
  module AdminUI
    module Helpers
      def self.feature_status_badge(status)
        case status.to_sym
        when :active
          '<span class="badge badge-success">Active</span>'
        when :deprecated
          '<span class="badge badge-warning">Deprecated</span>'
        when :inactive
          '<span class="badge badge-danger">Inactive</span>'
        else
          '<span class="badge">Unknown</span>'
        end
      end

      def self.feature_type_label(type)
        case type.to_sym
        when :boolean
          'Boolean'
        when :string
          'String'
        when :number
          'Number'
        else
          type.to_s.capitalize
        end
      end
    end
  end
end
