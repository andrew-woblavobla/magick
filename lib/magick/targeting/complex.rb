# frozen_string_literal: true

module Magick
  module Targeting
    class Complex < Base
      def initialize(conditions, operator: :and)
        @conditions = Array(conditions)
        @operator = operator.to_sym
      end

      def matches?(context)
        return false if @conditions.empty?

        case @operator
        when :and, :all
          @conditions.all? { |condition| condition.matches?(context) }
        when :or, :any
          @conditions.any? { |condition| condition.matches?(context) }
        else
          false
        end
      end
    end
  end
end
