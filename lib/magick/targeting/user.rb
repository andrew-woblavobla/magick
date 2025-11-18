# frozen_string_literal: true

module Magick
  module Targeting
    class User < Base
      def initialize(user_id)
        @user_id = user_id.to_s
      end

      def matches?(context)
        context[:user_id]&.to_s == @user_id
      end
    end
  end
end
