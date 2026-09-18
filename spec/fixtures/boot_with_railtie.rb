# frozen_string_literal: true

# Boots a throwaway Rails application the way a host does — `require 'magick'`
# with Rails already loaded — and reports what the Railtie set up. Run in its
# own process by spec/magick/rails/railtie_boot_spec.rb: booting Rails mutates
# the whole process (Rails.application, inflections, Object#feature), so it
# cannot share one with the rest of the suite.
require 'bundler/setup'
require 'json'
require 'action_controller/railtie'
require 'magick' # must load the Railtie itself: hosts use `require: 'magick'`

ENV['RAILS_ENV'] ||= 'development'

class RailtieBootApp < ::Rails::Application
  config.root = Dir.pwd
  config.eager_load = false
  config.logger = Logger.new(IO::NULL)
  config.secret_key_base = 'railtie-boot-spec'
  config.hosts.clear
  config.paths['config/routes.rb'] = []
end
RailtieBootApp.initialize!

require 'rack/mock'
status, = RailtieBootApp.call(Rack::MockRequest.env_for('/anything'))

report = {
  railtie: defined?(Magick::Rails::Railtie) ? 'loaded' : 'missing',
  middleware: RailtieBootApp.middleware.map(&:name),
  registry: Magick.adapter_registry.class.name,
  health: Magick.health.transform_values { |v| v.is_a?(Time) ? v.iso8601 : v },
  request_status: status,
  shutdown: Magick.shutdown!
}
puts JSON.generate(report)
