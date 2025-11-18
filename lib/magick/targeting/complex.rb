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

        results = @conditions.map { |condition| condition.matches?(context) }

        case @operator
        when :and, :all
          results.all?
        when :or, :any
          results.any?
        else
          false
        end
      end
    end
  end
end
