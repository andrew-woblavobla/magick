# frozen_string_literal: true

module Magick
  module Targeting
    class DateRange < Base
      def initialize(start_date, end_date)
        @start_date = start_date.is_a?(String) ? Time.parse(start_date) : start_date
        @end_date = end_date.is_a?(String) ? Time.parse(end_date) : end_date
      end

      def matches?(_context)
        now = Time.now
        now >= @start_date && now <= @end_date
      end
    end
  end
end
