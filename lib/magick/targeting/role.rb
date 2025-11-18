# frozen_string_literal: true

module Magick
  module Targeting
    class Role < Base
      def initialize(role_name)
        @role_name = role_name.to_s
      end

      def matches?(context)
        context[:role]&.to_s == @role_name
      end
    end
  end
end
