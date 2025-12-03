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

      # Rails engines automatically detect app/views and app/controllers directories
      # With isolate_namespace, views should be at:
      # app/views/magick/adminui/[controller]/[action].html.erb
      # Controllers should be at:
      # app/controllers/magick/adminui/[controller]_controller.rb
      # Rails handles this automatically, but we explicitly add app/controllers to autoload paths
      # to ensure controllers are found
      config.autoload_paths += %W[#{root}/app/controllers] if root.join('app', 'controllers').exist?

      # Explicitly add app/views to view paths
      # Rails engines should do this automatically, but we ensure it's configured
      initializer 'magick.admin_ui.append_view_paths', after: :add_view_paths do |app|
        app.paths['app/views'] << root.join('app', 'views').to_s if root.join('app', 'views').exist?
      end

      # Also ensure view paths are added when ActionController loads
      initializer 'magick.admin_ui.append_view_paths_to_controller', after: :add_view_paths do
        ActiveSupport.on_load(:action_controller) do
          view_path = Magick::AdminUI::Engine.root.join('app', 'views').to_s
          append_view_path view_path unless view_paths.include?(view_path)
        end
      end

      # Ensure view paths are added in to_prepare (runs before each request in development)
      config.to_prepare do
        view_path = Magick::AdminUI::Engine.root.join('app', 'views').to_s
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
