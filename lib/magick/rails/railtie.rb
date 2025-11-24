# frozen_string_literal: true

if defined?(Rails)
  # Ensure magick is loaded (in case auto-require didn't work)
  require 'magick' unless defined?(Magick)
  # DSL is already loaded by magick.rb, but ensure it's available
  require 'magick/dsl' unless defined?(Magick::DSL)
  require_relative 'events'

  module Magick
    module Rails
      class Railtie < ::Rails::Railtie
        # Make DSL available early so it works in config/initializers/features.rb
        initializer 'magick.dsl', before: :load_config_initializers do
          # Ensure DSL is available globally for initializers
          Object.class_eval { include Magick::DSL } unless Object.included_modules.include?(Magick::DSL)
        end

        initializer 'magick.configure', before: :load_config_initializers do |app|
          # Configure Magick with Rails-specific settings (only if not already configured)
          # This allows user's config/initializers/magick.rb to override these defaults
          unless Magick.adapter_registry
            Magick.configure do |magick|
              # Use Redis if available, otherwise fall back to memory
              if defined?(Redis)
                begin
                  redis_url = app.config.respond_to?(:redis_url) ? app.config.redis_url : nil
                  redis_client = redis_url ? ::Redis.new(url: redis_url) : ::Redis.new
                  memory_adapter = Adapters::Memory.new
                  redis_adapter = Adapters::Redis.new(redis_client)
                  magick.adapter_registry = Adapters::Registry.new(memory_adapter, redis_adapter)
                  # Enable Redis tracking if performance metrics exists and Redis is available
                  if Magick.performance_metrics && redis_adapter
                    Magick.performance_metrics.enable_redis_tracking(enable: true)
                  end
                rescue StandardError => e
                  Rails.logger&.warn "Magick: Failed to initialize Redis adapter: #{e.message}. Using memory-only adapter."
                  # Still set up memory adapter even if Redis fails
                  memory_adapter = Adapters::Memory.new
                  magick.adapter_registry = Adapters::Registry.new(memory_adapter, nil)
                end
              else
                # No Redis gem, use memory-only adapter
                memory_adapter = Adapters::Memory.new
                magick.adapter_registry = Adapters::Registry.new(memory_adapter, nil)
              end
            end
          end

          # Ensure adapter_registry is always set (fallback to default if not configured)
          unless Magick.adapter_registry
            Magick.adapter_registry = Magick.default_adapter_registry
          end

          # Ensure adapter_registry is set and Redis tracking is enabled after all initializers have run
          # This ensures user's config/initializers/magick.rb has been loaded
          config.after_initialize do
            # Ensure adapter_registry is set (fallback to default if not configured)
            unless Magick.adapter_registry
              Magick.adapter_registry = Magick.default_adapter_registry
            end

            # Force enable Redis tracking if Redis adapter is available
            # This is a final safety net to ensure stats are collected
            if Magick.performance_metrics && Magick.adapter_registry.is_a?(Adapters::Registry) && Magick.adapter_registry.redis_available?
              Magick.performance_metrics.enable_redis_tracking(enable: true)
              # Double-check it was enabled (for debugging)
              unless Magick.performance_metrics.redis_enabled
                Rails.logger&.warn 'Magick: Failed to enable Redis tracking despite Redis adapter being available'
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
              if File.exist?(initializer_file) && !defined?(Magick::Rails::FeaturesLoaded)
                # Only load if not already loaded (Rails may have already loaded it)
                load initializer_file
              end
            end
            begin
              Magick::Rails.const_set(:FeaturesLoaded, true)
            rescue StandardError
              nil
            end
          end
        end

        # Preload features in request store
        config.to_prepare do
          RequestStore.store[:magick_features] ||= {} if defined?(RequestStore)

          # Final check: ensure Redis tracking is enabled (runs on every request in development)
          # This is the absolute last chance to enable it
          if Magick.performance_metrics && Magick.adapter_registry.is_a?(Adapters::Registry) && Magick.adapter_registry.redis_available? && !Magick.performance_metrics.redis_enabled
            Magick.performance_metrics.enable_redis_tracking(enable: true)
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
