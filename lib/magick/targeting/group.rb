# frozen_string_literal: true

module Magick
  module Targeting
    class Group < Base
      def initialize(group_name)
        @group_name = group_name.to_s
      end

      def matches?(context)
        context[:group]&.to_s == @group_name
      end
    end
  end
end
