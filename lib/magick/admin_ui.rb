# frozen_string_literal: true

require_relative 'errors'
require_relative 'admin_ui/engine'
# Controllers are explicitly required in the Engine's config.to_prepare block
# This ensures they're loaded when the gem is used from RubyGems
require_relative 'admin_ui/helpers'
require_relative 'admin_ui/authentication'

module Magick
  module AdminUI
    class << self
      def configure
        yield config if block_given?
      end

      def config
        @config ||= Configuration.new
      end

      class Configuration
        attr_accessor :theme, :brand_name, :available_roles, :available_tags, :current_actor
        attr_reader :require_role

        def initialize
          @theme = :light
          @brand_name = 'Magick'
          @require_role = nil
          @available_roles = [] # Can be populated via DSL: admin_ui { roles ['admin', 'user', 'manager'] }
          @available_tags = nil # Can be array or lambda: -> { Tag.all }
          # Lambda receiving the controller, returning who is making the
          # change; stamped onto audit entries (user_id) and versions
          # (created_by): -> (controller) { controller.current_user&.id }
          @current_actor = nil
        end

        # The Admin UI authentication hook. nil (the default) leaves the
        # panel ungated, so the host can gate the mounted routes at the
        # router instead. Anything else must be callable: it receives the
        # controller and returns truthy to allow, falsey to deny with a 403.
        #
        # A non-callable value — a role name as a Symbol or String is the
        # common slip — cannot authenticate anything. It used to be accepted
        # and then skipped at request time, leaving the panel open while the
        # operator believed it was locked, so it is now refused outright.
        def require_role=(hook)
          unless hook.nil? || hook.respond_to?(:call)
            raise Magick::ConfigurationError,
                  'Magick::AdminUI.config.require_role must be callable (a lambda or proc ' \
                  'receiving the controller and returning true to allow) or nil to leave the ' \
                  "Admin UI ungated; got #{hook.class} (#{hook.inspect}). To gate by role, " \
                  'wrap the check in a lambda: ' \
                  'config.require_role = ->(controller) { controller.current_user&.admin? }'
          end

          @require_role = hook
        end

        # Get available tags, calling lambda if needed
        def tags
          return [] if @available_tags.nil?
          return @available_tags.call if @available_tags.respond_to?(:call)
          Array(@available_tags)
        end
      end
    end
  end
end
