# frozen_string_literal: true

# Availability gate for the Redis integration specs.
#
# These specs run in their own RSpec process (`rake spec:redis`, and the
# "Redis integration specs" step in CI). They cannot share a process with the
# rest of the suite: requiring the `redis` gem defines ::Redis, and Magick's
# adapter auto-detection keys off `defined?(Redis)`, so every other spec that
# touches `Magick.default_adapter_registry` would silently start reading and
# writing a real Redis and leaking state between examples.
#
# Hence two switches rather than one:
#   REDIS_URL           — where Redis lives (the gate the specs have always used)
#   MAGICK_REDIS_SPECS  — opt in to loading the gem and running these specs
#
# With MAGICK_REDIS_SPECS=1 the gate is strict: an unreachable Redis aborts the
# run instead of quietly skipping, so CI cannot go green on specs that never ran.
module RedisSpecSupport
  module_function

  def requested?
    ENV['MAGICK_REDIS_SPECS'] == '1'
  end

  def url
    ENV['REDIS_URL']
  end

  # Memoized so the gem is required (and Redis pinged) at most once per process.
  def available?
    return @available if defined?(@available)

    @available = requested? && connectable?
    abort(unavailable_message) if requested? && !@available
    @available
  end

  def new_client
    ::Redis.new(url: url)
  end

  def connectable?
    return false unless url

    require 'redis'
    new_client.ping
    true
  rescue LoadError, StandardError => e
    @failure = "#{e.class}: #{e.message}"
    false
  end

  def unavailable_message
    if url
      "MAGICK_REDIS_SPECS=1 but Redis at #{url} is not usable (#{@failure}). " \
        'Start Redis or unset MAGICK_REDIS_SPECS.'
    else
      'MAGICK_REDIS_SPECS=1 but REDIS_URL is not set. ' \
        'Set REDIS_URL (e.g. redis://localhost:6379/1) or unset MAGICK_REDIS_SPECS.'
    end
  end
end
