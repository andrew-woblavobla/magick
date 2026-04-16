# frozen_string_literal: true

module Magick
  module AdminUI
    class StatsController < ActionController::Base
      include ::ActionController::RequestForgeryProtection
      protect_from_forgery with: :exception

      include Magick::AdminUI::Engine.routes.url_helpers
      layout 'application'

      helper_method :magick_admin_ui

      def magick_admin_ui
        Magick::AdminUI::Engine.routes.url_helpers
      end

      def show
        feature_name = params[:id].to_s
        @feature = Magick.features[feature_name]
        unless @feature
          head :not_found
          return
        end
        @stats = Magick.feature_stats(feature_name.to_sym) || {}
      end
    end
  end
end
