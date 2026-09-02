# frozen_string_literal: true

require_relative '../errors'

module Magick
  module AdminUI
    # The Admin UI's authentication gate, shared by every controller in the
    # engine.
    #
    # Authentication is opt-in. With `Magick::AdminUI.config.require_role`
    # left nil the panel stays open and the host is expected to gate the
    # mounted routes at the router — the pattern the README recommends and
    # the more robust of the two, since it covers everything the engine
    # mounts, including routes added by a later version of this gem.
    #
    # Once the hook *is* set it has to gate every route the engine exposes.
    # Controllers therefore `include` this module instead of declaring their
    # own `before_action`, so a controller cannot be added without the gate:
    # the stats route shipped unauthenticated for exactly that reason.
    #
    # The decision is fail-closed. A hook that is present but not callable
    # denies rather than falling through to "no authentication at all" — an
    # operator who configured `require_role` believes the panel is locked,
    # and a silent no-op would make that belief wrong. `Configuration#
    # require_role=` already rejects such a value at assignment time; this is
    # the backstop for a value that reached the config another way (an
    # `instance_variable_set`, a deserialized config object).
    #
    # An exception raised *by* the hook is deliberately not rescued. The
    # request is denied either way — Rails renders a 500 — and the backtrace
    # is what tells the operator their auth code is broken. Swallowing it
    # would hide a real bug in the host app.
    module Authentication
      class << self
        # The authorization policy on its own: `:allow` or `:deny`, with no
        # Rails in sight, so it can be tested and reasoned about directly.
        #
        #   nil hook          -> :allow  (opt-in; gate at the router instead)
        #   callable, truthy  -> :allow
        #   callable, falsey  -> :deny
        #   anything else     -> :deny   (a Symbol/String cannot authenticate)
        def decision(hook, controller = nil)
          return :allow if hook.nil?
          return :deny unless hook.respond_to?(:call)

          hook.call(controller) ? :allow : :deny
        end

        # Installing the filter here (rather than in each controller) is the
        # point of the module: including it is what wires the gate up.
        def included(base)
          base.before_action :authenticate_admin!
        end
      end

      private

      def authenticate_admin!
        return if Authentication.decision(Magick::AdminUI.config.require_role, self) == :allow

        head :forbidden
      end
    end
  end
end
