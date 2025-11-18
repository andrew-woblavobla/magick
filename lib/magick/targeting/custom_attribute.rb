# frozen_string_literal: true

module Magick
  module Targeting
    class CustomAttribute < Base
      def initialize(attribute_name, values, operator: :equals)
        @attribute_name = attribute_name.to_sym
        @values = Array(values)
        @operator = operator.to_sym
      end

      def matches?(context)
        context_value = context[@attribute_name] || context[@attribute_name.to_s]
        return false if context_value.nil?

        case @operator
        when :equals, :eq
          @values.include?(context_value.to_s)
        when :not_equals, :ne
          !@values.include?(context_value.to_s)
        when :in
          @values.include?(context_value.to_s)
        when :not_in
          !@values.include?(context_value.to_s)
        when :greater_than, :gt
          context_value.to_f > @values.first.to_f
        when :less_than, :lt
          context_value.to_f < @values.first.to_f
        else
          false
        end
      end
    end
  end
end
