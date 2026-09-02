# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

namespace :spec do
  # Own process, and only the :redis-tagged examples: loading the `redis` gem
  # defines ::Redis, which flips Magick's adapter auto-detection for everything
  # else in the run. See spec/support/redis.rb.
  task :redis_env do
    ENV['MAGICK_REDIS_SPECS'] = '1'
    ENV['REDIS_URL'] ||= 'redis://localhost:6379/1'
  end

  desc 'Run the Redis integration specs (needs a reachable REDIS_URL, default redis://localhost:6379/1)'
  RSpec::Core::RakeTask.new(redis: :redis_env) do |t|
    t.rspec_opts = '--tag redis'
  end
end

task default: :spec
