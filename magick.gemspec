# frozen_string_literal: true

require_relative 'lib/magick/version'

Gem::Specification.new do |spec|
  spec.name          = 'magick-feature-flags'
  spec.version       = Magick::VERSION
  spec.authors       = ['Andrew Lobanov']
  spec.email         = ['woblavobla@gmail.com']

  spec.summary       = 'A performant and memory-efficient feature toggle gem'
  spec.description   = 'Magick is a better free version of Flipper feature-toggle gem. It is absolutely performant and memory efficient (by my opinion).'
  spec.homepage      = 'https://github.com/andrew-woblavobla/magick'
  spec.license       = 'MIT'

  spec.files         = Dir['lib/**/*', 'app/**/*', 'config/**/*', 'README.md', 'LICENSE']
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 3.2.0'

  # Redis is optional - gem works without it using memory-only adapter
  # spec.add_dependency 'redis', '~> 5.0'

  spec.add_development_dependency 'rspec', '~> 3.12'
  spec.add_development_dependency 'rubocop', '~> 1.50'
  spec.add_development_dependency 'rubocop-rspec', '~> 3.8'
  # Optional dependencies for ActiveRecord adapter testing
  spec.add_development_dependency 'activerecord', '>= 6.0', '< 9.0'
  spec.add_development_dependency 'sqlite3', '~> 2.0'
end
