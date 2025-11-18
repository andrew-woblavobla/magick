# frozen_string_literal: true

if defined?(Rails)
  require 'magick'
  require 'magick/dsl'
  require_relative 'events'

  module Magick
    module Rails
      class Railtie < ::Rails::Railtie
        # Make DSL available early so it works in config/initializers/features.rb
        initializer 'magick.dsl', before: :load_config_initializers do
          # Ensure DSL is available globally for initializers
          Object.class_eval { include Magick::DSL } unless Object.included_modules.include?(Magick::DSL)
        end

        initializer 'magick.configure' do |app|
          # Configure Magick with Rails-specific settings
          Magick.configure do |config|
            # Use Redis if available, otherwise fall back to memory
            if defined?(Redis)
              begin
                redis_url = app.config.respond_to?(:redis_url) ? app.config.redis_url : nil
                redis_client = redis_url ? ::Redis.new(url: redis_url) : ::Redis.new
                memory_adapter = Adapters::Memory.new
                redis_adapter = Adapters::Redis.new(redis_client)
                config.adapter_registry = Adapters::Registry.new(memory_adapter, redis_adapter)
              rescue StandardError => e
                Rails.logger&.warn "Magick: Failed to initialize Redis adapter: #{e.message}. Using memory-only adapter."
              end
            end
          end

          # Load features from DSL file if it exists
          # Supports both config/features.rb and config/initializers/features.rb
          config.after_initialize do
            # Try config/features.rb first (recommended location)
            features_file = Rails.root.join('config', 'features.rb')
            if File.exist?(features_file)
              load features_file
            else
              # Fallback to config/initializers/features.rb (already loaded by Rails, but check anyway)
              initializer_file = Rails.root.join('config', 'initializers', 'features.rb')
              if File.exist?(initializer_file)
                # Only load if not already loaded (Rails may have already loaded it)
                load initializer_file unless defined?(Magick::Rails::FeaturesLoaded)
              end
            end
            Magick::Rails.const_set(:FeaturesLoaded, true) rescue nil
          end
        end

        # Preload features in request store
        config.to_prepare do
          if defined?(RequestStore)
            RequestStore.store[:magick_features] ||= {}
          end
        end
      end
    end

    # Request store integration
    module RequestStoreIntegration
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def enabled?(feature_name, context = {})
          # Check request store cache first
          if defined?(RequestStore)
            cache_key = "#{feature_name}:#{context.hash}"
            cached = RequestStore.store[:magick_features]&.[](cache_key)
            return cached unless cached.nil?
          end

          # Check feature
          result = super(feature_name, context)

          # Cache in request store
          if defined?(RequestStore)
            RequestStore.store[:magick_features] ||= {}
            RequestStore.store[:magick_features][cache_key] = result
          end

          result
        end
      end
    end
  end

  # Extend Magick module with request store integration
  Magick.extend(Magick::Rails::RequestStoreIntegration)
end
