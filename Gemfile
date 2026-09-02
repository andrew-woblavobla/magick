# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.2.0'

gemspec

gem 'rake', '~> 13.0'

group :development, :test do
  gem 'rspec', '~> 3.12'
  gem 'rubocop', '~> 1.50'
  gem 'rubocop-rspec', '~> 3.8'
  # Optional dependencies for ActiveRecord adapter testing
  gem 'activerecord', '>= 6.0', '< 9.0', require: false
  gem 'sqlite3', '~> 2.0', require: false
  # Optional dependency powering per-request caching of feature checks
  gem 'request_store', '~> 1.5', require: false
  # Optional dependency for Redis adapter / Pub/Sub integration testing
  gem 'redis', '~> 5.0', require: false
end
