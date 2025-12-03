# frozen_string_literal: true

require_relative 'admin_ui/engine'
# Controllers are explicitly required in the Engine's config.to_prepare block
# This ensures they're loaded when the gem is used from RubyGems
require_relative 'admin_ui/helpers'

module Magick
  module AdminUI
    class << self
      def configure
        yield config if block_given?
      end

      def config
        @config ||= Configuration.new
      end

      class Configuration
        attr_accessor :theme, :brand_name, :require_role, :available_roles

        def initialize
          @theme = :light
          @brand_name = 'Magick'
          @require_role = nil
          @available_roles = [] # Can be populated via DSL: admin_ui { roles ['admin', 'user', 'manager'] }
        end
      end
    end
  end
end
