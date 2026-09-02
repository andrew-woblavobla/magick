# frozen_string_literal: true

require 'spec_helper'
require_relative '../rails_helper'

# The Admin UI's controllers, views and authentication are exercised over real
# requests against a mounted engine in spec/magick/admin_ui/. What is left here
# is the engine's public surface and its configuration object.
if MagickRailsApp.available?
  RSpec.describe Magick::AdminUI do
    around do |example|
      config = described_class.config
      previous = {
        theme: config.theme,
        brand_name: config.brand_name,
        require_role: config.require_role,
        available_roles: config.available_roles,
        available_tags: config.available_tags
      }
      example.run
    ensure
      config.theme = previous[:theme]
      config.brand_name = previous[:brand_name]
      config.instance_variable_set(:@require_role, previous[:require_role])
      config.available_roles = previous[:available_roles]
      config.available_tags = previous[:available_tags]
    end

    describe 'mounting in Rails' do
      it 'can be mounted as Rails engine' do
        expect(described_class::Engine).to be < Rails::Engine
      end

      it 'provides mountable routes' do
        expect(described_class::Engine.routes.url_helpers).to respond_to(:features_path)
      end
    end

    describe 'configuration' do
      it 'allows customizing UI appearance' do
        described_class.configure do |config|
          config.theme = :dark
          config.brand_name = 'My App'
        end

        expect(described_class.config.theme).to eq(:dark)
        expect(described_class.config.brand_name).to eq('My App')
      end

      # Enforcement of the configured hook lives in
      # spec/magick/admin_ui/authentication_request_spec.rb — asserting that a
      # value round-trips proves nothing about whether the panel is gated.
      it 'accepts a callable authentication hook' do
        hook = ->(controller) { controller.respond_to?(:params) }
        described_class.configure { |config| config.require_role = hook }

        expect(described_class.config.require_role).to be(hook)
      end

      it 'refuses a role name that cannot authenticate anything' do
        expect { described_class.configure { |config| config.require_role = :admin } }
          .to raise_error(Magick::ConfigurationError, /must be callable/)
      end

      it 'allows configuring available tags as array' do
        described_class.configure do |config|
          config.available_tags = %w[premium beta vip]
        end

        expect(described_class.config.tags).to eq(%w[premium beta vip])
      end

      it 'allows configuring available tags as lambda' do
        tag_lambda = -> { [double(id: 1, name: 'premium'), double(id: 2, name: 'beta')] }
        described_class.configure do |config|
          config.available_tags = tag_lambda
        end

        tags = described_class.config.tags
        expect(tags.length).to eq(2)
        expect(tags.first.id).to eq(1)
        expect(tags.first.name).to eq('premium')
      end

      it 'returns empty array when tags are nil' do
        described_class.configure do |config|
          config.available_tags = nil
        end

        expect(described_class.config.tags).to eq([])
      end

      it 'calls lambda each time tags are accessed' do
        call_count = 0
        tag_lambda = lambda {
          call_count += 1
          %w[tag1 tag2]
        }
        described_class.configure do |config|
          config.available_tags = tag_lambda
        end

        expect(call_count).to eq(0)
        described_class.config.tags
        expect(call_count).to eq(1)
        described_class.config.tags
        expect(call_count).to eq(2)
      end
    end
  end
else
  RSpec.describe 'Magick::AdminUI' do
    it 'requires Rails to be available' do
      skip 'Admin UI requires Rails'
    end
  end
end
