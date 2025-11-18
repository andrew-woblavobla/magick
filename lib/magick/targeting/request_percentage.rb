# frozen_string_literal: true

module Magick
  module Targeting
    class RequestPercentage < Base
      def initialize(percentage)
        @percentage = percentage.to_f
      end

      def matches?(_context)
        rand(100) < @percentage
      end
    end
  end
end
