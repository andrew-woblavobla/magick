# frozen_string_literal: true

# The gem's log/event surface only exists under Rails: error-severity logging
# goes to `Rails.logger`, and the structured event channel is `Rails.event`.
# Neither is loaded in this suite, so specs that assert on them stand up a
# minimal recording double for the duration of one example and take it back
# down afterwards.
module FakeRails
  class Logger
    attr_reader :errors, :warnings, :infos

    def initialize
      @errors = []
      @warnings = []
      @infos = []
    end

    def error(message = nil, &block) = @errors << (message || block&.call)
    def warn(message = nil, &block) = @warnings << (message || block&.call)
    def info(message = nil, &block) = @infos << (message || block&.call)
    def debug(message = nil, &block); end
  end

  # Stands in for Rails 8.1's `Rails.event` reporter.
  class EventReporter
    attr_reader :events

    def initialize
      @events = []
    end

    def notify(name, payload = {})
      @events << { name: name, payload: payload }
    end
  end

  class Env
    def initialize(name) = @name = name
    def development? = @name == 'development'
    def test? = @name == 'test'
    def production? = @name == 'production'
    def to_s = @name
  end

  # Build a stand-in for the top-level `Rails` constant. Defaults to production
  # so specs prove the gem still talks when it is not in development.
  #
  # Pass `env: 'test'` when the example needs to build a Registry with a Redis
  # adapter: the Pub/Sub subscriber thread is skipped in the test environment.
  def self.build(logger:, event:, env: 'production')
    environment = Env.new(env)
    Class.new do
      define_singleton_method(:logger) { logger }
      define_singleton_method(:event) { event }
      define_singleton_method(:env) { environment }
    end
  end

  EVENTS_PATH = File.expand_path('../../lib/magick/rails/events.rb', __dir__)

  # Load the real structured-event module for one example.
  #
  # It cannot simply be required by the whole suite: defining `Magick::Rails`
  # makes a bare `Rails` inside any `module Magick` body resolve to it instead
  # of the framework, which changes how unrelated code in the gem behaves. So
  # it is loaded per-example and removed again.
  #
  # Only removed if this method is what introduced it. A host that has loaded
  # the railtie owns `Magick::Rails` (it holds `Magick::Rails::Railtie`), and
  # tearing that down here would break every example that followed.
  def self.with_event_channel
    preexisting = Magick.const_defined?(:Rails, false)
    load EVENTS_PATH
    yield
  ensure
    Magick.send(:remove_const, :Rails) if !preexisting && Magick.const_defined?(:Rails, false)
  end
end
