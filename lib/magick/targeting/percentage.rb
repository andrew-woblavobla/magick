# frozen_string_literal: true

require 'digest'

module Magick
  module Targeting
    class Percentage < Base
      def initialize(percentage, feature_name, user_id = nil)
        @percentage = percentage.to_f
        @feature_name = feature_name.to_s
        @user_id = user_id&.to_s
      end

      def matches?(context)
        user_id = (@user_id || context[:user_id])&.to_s
        return false unless user_id

        hash = Digest::MD5.hexdigest("#{@feature_name}:#{user_id}")
        hash_value = hash[0..7].to_i(16)
        (hash_value % 100) < @percentage
      end
    end
  end
end
