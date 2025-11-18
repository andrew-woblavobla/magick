# frozen_string_literal: true

# Rails integration is now in lib/magick/rails/railtie.rb
# This file is kept for backward compatibility
if defined?(Rails)
  require_relative 'rails/railtie'
end
