# frozen_string_literal: true

# Configure inflector immediately when this file loads
# This ensures AdminUI stays as AdminUI (not AdminUi) before Rails processes routes
if defined?(ActiveSupport::Inflector)
  ActiveSupport::Inflector.inflections(:en) do |inflect|
    inflect.acronym 'AdminUI'
    inflect.acronym 'UI'
  end
end

module Magick
  module AdminUI
    class Engine < ::Rails::Engine
      isolate_namespace Magick::AdminUI

      engine_name 'magick_admin_ui'

      # Ensure the engine doesn't interfere with Warden/Devise middleware
      # Rails engines by default inherit middleware from the main app, which is what we want
      # We don't add any custom middleware that could interfere with Warden/Devise
      # The engine should work alongside existing authentication middleware without modification

      # Rails engines automatically detect app/views and app/controllers directories
      # With isolate_namespace, views should be at:
      # app/views/magick/adminui/[controller]/[action].html.erb
      # Controllers should be at:
      # app/controllers/magick/adminui/[controller]_controller.rb
      # Rails handles this automatically, but we explicitly add app/controllers to autoload paths
      # to ensure controllers are found
      config.autoload_paths += %W[#{root}/app/controllers] if root.join('app', 'controllers').exist?

      # Explicitly require controllers early to ensure they're loaded when gem is from RubyGems
      # This initializer runs before routes are drawn
      initializer 'magick.admin_ui.require_controllers', before: :load_config_initializers do
        engine_root = Magick::AdminUI::Engine.root
        controller_path = engine_root.join('app', 'controllers', 'magick', 'adminui', 'features_controller.rb')
        require controller_path.to_s if controller_path.exist?

        stats_controller_path = engine_root.join('app', 'controllers', 'magick', 'adminui', 'stats_controller.rb')
        require stats_controller_path.to_s if stats_controller_path.exist?
      end

      # Explicitly add app/views to view paths
      # Rails engines should do this automatically, but we ensure it's configured
      initializer 'magick.admin_ui.append_view_paths', after: :add_view_paths do |app|
        engine_root = Magick::AdminUI::Engine.root
        app.paths['app/views'] << engine_root.join('app', 'views').to_s if engine_root.join('app', 'views').exist?
      end

      # Also ensure view paths are added when ActionController loads
      initializer 'magick.admin_ui.append_view_paths_to_controller', after: :add_view_paths do
        ActiveSupport.on_load(:action_controller) do
          view_path = Magick::AdminUI::Engine.root.join('app', 'views').to_s
          append_view_path view_path unless view_paths.include?(view_path)
        end
      end

      # Ensure controllers are loaded and view paths are added in to_prepare
      # This runs before each request in development and once at boot in production
      config.to_prepare do
        # Explicitly require controllers first to ensure they're loaded
        # This is necessary when the gem is loaded from RubyGems
        engine_root = Magick::AdminUI::Engine.root
        controller_path = engine_root.join('app', 'controllers', 'magick', 'adminui', 'features_controller.rb')
        require controller_path.to_s if controller_path.exist?

        stats_controller_path = engine_root.join('app', 'controllers', 'magick', 'adminui', 'stats_controller.rb')
        require stats_controller_path.to_s if stats_controller_path.exist?

        # Then add view paths
        view_path = engine_root.join('app', 'views').to_s
        if File.directory?(view_path)
          if defined?(Magick::AdminUI::FeaturesController)
            Magick::AdminUI::FeaturesController.append_view_path(view_path)
          end
          Magick::AdminUI::StatsController.append_view_path(view_path) if defined?(Magick::AdminUI::StatsController)
        end
      end
    end
  end
end

# Draw routes directly - Rails engines should auto-load config/routes.rb
# but for gems we need to ensure routes are drawn at the right time
# Use both to_prepare (for development reloading) and an initializer (for production)
if defined?(Rails)
  # Initializer runs once during app initialization
  Magick::AdminUI::Engine.initializer 'magick.admin_ui.draw_routes', after: :load_config_initializers do
    Magick::AdminUI::Engine.routes.draw do
      root 'features#index'
      resources :features, only: %i[index show edit update] do
        member do
          put :enable
          put :disable
          put :enable_for_user
          put :enable_for_role
          put :disable_for_role
          put :update_targeting
        end
      end
      resources :stats, only: [:show]
    end
  end

  # to_prepare runs before each request in development (for code reloading)
  Magick::AdminUI::Engine.config.to_prepare do
    # Routes are already drawn by initializer, but redraw if needed for development reloading
    if Magick::AdminUI::Engine.routes.routes.empty?
      Magick::AdminUI::Engine.routes.draw do
        root 'features#index'
        resources :features, only: %i[index show edit update] do
          member do
            put :enable
            put :disable
            put :enable_for_user
            put :enable_for_role
            put :disable_for_role
            put :update_targeting
          end
        end
        resources :stats, only: [:show]
      end
    end
  end
end
