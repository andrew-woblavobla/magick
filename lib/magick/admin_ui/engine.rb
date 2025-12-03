# frozen_string_literal: true

# Configure inflector immediately when this file loads
# This ensures AdminUI stays as AdminUI (not AdminUi) before Rails processes routes
if defined?(ActiveSupport::Inflector)
  ActiveSupport::Inflector.inflections(:en) do |inflect|
    inflect.acronym 'AdminUI'
    inflect.acronym 'UI'
  end
end

module Magick
  module AdminUI
    class Engine < ::Rails::Engine
      isolate_namespace Magick::AdminUI

      engine_name 'magick_admin_ui'
    end
  end
end
