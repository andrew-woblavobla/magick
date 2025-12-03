# frozen_string_literal: true

module Magick
  module AdminUI
    class StatsController < ActionController::Base
      include Magick::AdminUI::Engine.routes.url_helpers
      layout 'application'

      helper_method :magick_admin_ui

      def magick_admin_ui
        Magick::AdminUI::Engine.routes.url_helpers
      end

      def show
        @feature = Magick.features[params[:id].to_s] || Magick[params[:id]]
        @stats = Magick.feature_stats(params[:id].to_sym) || {} if @feature
      end
    end
  end
end
