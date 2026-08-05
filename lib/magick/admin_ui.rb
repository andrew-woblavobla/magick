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
        attr_accessor :theme, :brand_name, :require_role, :available_roles, :available_tags, :current_actor

        def initialize
          @theme = :light
          @brand_name = 'Magick'
          @require_role = nil
          @available_roles = [] # Can be populated via DSL: admin_ui { roles ['admin', 'user', 'manager'] }
          @available_tags = nil # Can be array or lambda: -> { Tag.all }
          # Lambda receiving the controller, returning who is making the
          # change; stamped onto audit entries (user_id) and versions
          # (created_by): -> (controller) { controller.current_user&.id }
          @current_actor = nil
        end

        # Get available tags, calling lambda if needed
        def tags
          return [] if @available_tags.nil?
          return @available_tags.call if @available_tags.respond_to?(:call)
          Array(@available_tags)
        end
      end
    end
  end
end
