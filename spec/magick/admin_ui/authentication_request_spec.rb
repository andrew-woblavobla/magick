# frozen_string_literal: true

require 'spec_helper'
require_relative '../../rails_helper'

if MagickRailsApp.available?
  ADMIN_UI_FEATURE = 'admin_ui_auth_flag'

  # Params that keep each action on its happy path, so an allowed request can
  # be asserted to actually succeed rather than merely "not 403".
  ADMIN_UI_ACTION_PARAMS = {
    'update' => { value: 'true' },
    'enable_for_user' => { user_id: '42' },
    'enable_for_role' => { role: 'admin' },
    'disable_for_role' => { role: 'admin' },
    'update_targeting' => { targeting: { roles: ['admin'] } },
    'update_variants' => { variants: {} }
  }.freeze

  # Read from the engine's route set rather than hard-coded, so a route added
  # by a later version of the gem is covered here the day it is added — the
  # stats route was open precisely because nothing checked the whole set.
  ADMIN_UI_ROUTES = MagickRailsApp.engine_routes

  # Exercises the mounted engine over real requests.
  RSpec.describe 'Admin UI authentication over the mounted engine' do
    include Rack::Test::Methods

    def app
      Rails.application
    end

    def request_route(route)
      path = MagickRailsApp.path_for(route[:route], id: ADMIN_UI_FEATURE)
      public_send(route[:verb].downcase, path, ADMIN_UI_ACTION_PARAMS.fetch(route[:action], {}))
    end

    around do |example|
      previous = Magick::AdminUI.config.require_role
      example.run
    ensure
      Magick::AdminUI.config.instance_variable_set(:@require_role, previous)
    end

    before { Magick.register_feature(ADMIN_UI_FEATURE.to_sym, type: :boolean, default_value: false) }

    it 'covers both Admin UI controllers' do
      controllers = ADMIN_UI_ROUTES.map { |route| route[:controller] }.uniq

      expect(controllers).to contain_exactly('magick/adminui/features', 'magick/adminui/stats')
    end

    context 'when require_role denies' do
      before { Magick::AdminUI.config.require_role = ->(_controller) { false } }

      ADMIN_UI_ROUTES.each do |route|
        it "forbids #{route[:verb]} #{route[:path_spec]} (#{route[:controller]}##{route[:action]})" do
          request_route(route)

          expect(last_response.status).to eq(403)
        end
      end

      it 'does not leak whether a feature name exists via the stats route' do
        get "/magick/stats/#{ADMIN_UI_FEATURE}"
        known = last_response.status
        get '/magick/stats/no_such_feature_at_all'

        expect([known, last_response.status]).to eq([403, 403])
      end
    end

    context 'when require_role is configured with a non-callable value' do
      # The writer refuses this outright, so the only way a config can hold
      # one is to bypass it (a pre-upgrade config object, a deserialized one).
      # The request must still be denied rather than sail through ungated.
      before { Magick::AdminUI.config.instance_variable_set(:@require_role, :admin) }

      ADMIN_UI_ROUTES.each do |route|
        it "forbids #{route[:verb]} #{route[:path_spec]} (#{route[:controller]}##{route[:action]})" do
          request_route(route)

          expect(last_response.status).to eq(403)
        end
      end
    end

    context 'when require_role allows' do
      before { Magick::AdminUI.config.require_role = ->(_controller) { true } }

      ADMIN_UI_ROUTES.each do |route|
        it "serves #{route[:verb]} #{route[:path_spec]} (#{route[:controller]}##{route[:action]})" do
          request_route(route)

          expect(last_response.status).to be < 400
        end
      end

      it 'hands the Admin UI controller to the hook' do
        seen = nil
        Magick::AdminUI.config.require_role = lambda do |controller|
          seen = controller
          true
        end

        get "/magick/stats/#{ADMIN_UI_FEATURE}"

        expect(seen).to be_a(Magick::AdminUI::StatsController)
      end
    end

    context 'when require_role is left nil' do
      before { Magick::AdminUI.config.require_role = nil }

      ADMIN_UI_ROUTES.each do |route|
        it "still serves #{route[:verb]} #{route[:path_spec]} (#{route[:controller]}##{route[:action]})" do
          request_route(route)

          expect(last_response.status).to be < 400
        end
      end
    end
  end
else
  RSpec.describe 'Admin UI authentication over the mounted engine' do
    it 'requires the Rails development dependencies' do
      skip 'Admin UI request specs require actionpack/actionview/railties/rack-test'
    end
  end
end
