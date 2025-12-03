# frozen_string_literal: true

# Routes file - users should add this to their Rails app's config/routes.rb:
# mount Magick::AdminUI::Engine, at: '/magick'
#
# Or define routes manually:
# Magick::AdminUI::Engine.routes.draw do
#   root 'features#index'
#   resources :features, only: [:index, :show, :edit, :update] do
#     member do
#       put :enable
#       put :disable
#       put :enable_for_user
#     end
#   end
#   resources :stats, only: [:show]
# end
