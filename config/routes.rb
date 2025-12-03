# frozen_string_literal: true

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
