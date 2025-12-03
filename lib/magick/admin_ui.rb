# frozen_string_literal: true

require_relative 'admin_ui/engine'
# Controllers are in app/controllers and will be auto-loaded by Rails engine
# But we explicitly require them to ensure they're available when needed
if defined?(Rails) && Rails.env
  # In Rails, controllers are auto-loaded from app/controllers
  # But we can explicitly require them if needed for console access
  engine_root = Magick::AdminUI::Engine.root
  if engine_root.join('app', 'controllers', 'magick', 'adminui', 'features_controller.rb').exist?
    require engine_root.join('app', 'controllers', 'magick', 'adminui', 'features_controller').to_s
  end
  if engine_root.join('app', 'controllers', 'magick', 'adminui', 'stats_controller.rb').exist?
    require engine_root.join('app', 'controllers', 'magick', 'adminui', 'stats_controller').to_s
  end
end
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
