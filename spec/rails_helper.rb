# frozen_string_literal: true

require 'spec_helper'

# Boots a throwaway Rails application with the Admin UI engine mounted, so the
# engine's routes can be exercised as real HTTP requests.
#
# Deliberately NOT under spec/support: spec_helper requires every file there,
# and booting Rails flips `defined?(Rails)` for the whole process. Only the
# specs that need a mounted engine require this file — the rspec-rails
# `rails_helper` convention, for the same reason rspec-rails has it.
module MagickRailsApp
  # The application's root. The gem root on purpose, not a scratch directory:
  # `Magick::ConfigDSL.project_root` prefers `Rails.root` when Rails is
  # defined, so pointing anywhere else would quietly move the config-load
  # containment boundary for every other spec in the process.
  GEM_ROOT = File.expand_path('..', __dir__)

  # Whether a Rails app could be booted. The Rails pieces are development
  # dependencies; without them the Admin UI specs skip instead of erroring.
  def self.available?
    @available
  end

  # Full request path for an engine route, with `:id` filled in.
  def self.path_for(route, id: nil)
    path = route.path.spec.to_s.sub('(.:format)', '')
    path = path.sub(':id', id.to_s) if id
    "/magick#{path}".chomp('/').then { |p| p.empty? ? '/magick' : p }
  end

  # Every route the mounted engine exposes, as { verb:, path_spec:, controller:,
  # action:, route: }. Enumerated from the route set rather than hard-coded, so
  # a route added later is covered by the authentication specs automatically.
  def self.engine_routes
    Magick::AdminUI::Engine.routes.routes.filter_map do |route|
      verb = route.verb.to_s.gsub(/[$^]/, '')
      next if verb.empty?

      { verb: verb, route: route, path_spec: route.path.spec.to_s.sub('(.:format)', ''),
        controller: route.defaults[:controller], action: route.defaults[:action] }
    end
  end

  begin
    require 'action_controller/railtie'
    require 'action_view/railtie'
    require 'rack/test'
    require 'magick/admin_ui'

    # Deliberately NOT the "test" environment. Several library paths branch on
    # `Rails.env.test?` — notably the Redis pub/sub subscriber, which skips
    # starting itself there — and booting this app changes `Rails.env` for the
    # whole process. Leaving it at the default keeps every other spec running
    # against the same code paths it ran against before Rails was in the room.
    ENV['RAILS_ENV'] ||= 'development'

    class Application < ::Rails::Application
      config.root = GEM_ROOT
      config.eager_load = false
      config.logger = Logger.new(IO::NULL)
      config.secret_key_base = 'magick-admin-ui-specs-secret-key-base'
      config.hosts.clear
      # The app shares its root with the engine, so it would otherwise pick up
      # the engine's config/routes.rb as its own and draw it a second time.
      config.paths['config/routes.rb'] = []
      # CSRF is covered by the controllers' own `protect_from_forgery`; turning
      # it off here means a non-GET request's status reflects authentication
      # alone rather than a missing token.
      config.action_controller.allow_forgery_protection = false

      # Mounted bare — no router-level `authenticate` block — so the specs
      # exercise the gem's own `require_role` gate rather than a host's.
      routes.append do
        mount Magick::AdminUI::Engine, at: '/magick'
      end
    end
    Application.initialize!

    @available = true
  rescue LoadError => e
    warn "Magick specs: skipping Admin UI request specs (#{e.message})"
    @available = false
  end
end
