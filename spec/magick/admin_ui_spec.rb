# frozen_string_literal: true

require 'spec_helper'

# Skip entire spec if Rails is not available
if defined?(Rails)
  require_relative '../../lib/magick/admin_ui'

  RSpec.describe Magick::AdminUI do
    # TODO: Implement admin UI for managing features
    # Requirements:
    # - Admin panel for managing features
    # - Must be easily integrated into Rails app
    # - Should provide web interface for CRUD operations
    # - Should show feature statistics and targeting

  describe 'mounting in Rails' do
    it 'can be mounted as Rails engine' do
      expect(described_class::Engine).to be < Rails::Engine
    end

    it 'provides mountable routes' do
      routes = described_class::Engine.routes
      expect(routes.url_helpers).to respond_to(:magick_features_path)
    end
  end

  describe 'views' do
    it 'provides index view for listing features' do
      Magick.register_feature(:test_feature, type: :boolean, default_value: false)
      view = described_class::FeaturesController.new.index
      expect(view).to be_present
    end

    it 'provides show view for feature details' do
      Magick.register_feature(:test_feature, type: :boolean, default_value: false)
      view = described_class::FeaturesController.new.show
      expect(view).to be_present
    end

    it 'provides edit view for modifying features' do
      Magick.register_feature(:test_feature, type: :boolean, default_value: false)
      view = described_class::FeaturesController.new.edit
      expect(view).to be_present
    end
  end

  describe 'controllers' do
    describe 'FeaturesController' do
      it 'lists all features' do
        Magick.register_feature(:feature1, type: :boolean, default_value: false)
        Magick.register_feature(:feature2, type: :boolean, default_value: false)
        controller = described_class::FeaturesController.new
        result = controller.index
        expect(result[:features].length).to eq(2)
      end

      it 'shows feature details' do
        Magick.register_feature(:test_feature, type: :boolean, default_value: false, description: 'Test')
        controller = described_class::FeaturesController.new
        result = controller.show
        expect(result[:feature].name).to eq('test_feature')
      end

      it 'updates feature value' do
        Magick.register_feature(:test_feature, type: :boolean, default_value: false)
        controller = described_class::FeaturesController.new
        controller.update(value: true)
        expect(Magick[:test_feature].value).to be true
      end

      it 'enables feature for user' do
        Magick.register_feature(:test_feature, type: :boolean, default_value: false)
        controller = described_class::FeaturesController.new
        controller.enable_for_user(user_id: 123)
        expect(Magick.enabled?(:test_feature, user_id: 123)).to be true
      end
    end

    describe 'StatsController' do
      it 'shows feature statistics' do
        Magick.register_feature(:test_feature, type: :boolean, default_value: false)
        Magick.enabled?(:test_feature) # Trigger usage
        controller = described_class::StatsController.new
        result = controller.show
        expect(result[:stats]).to have_key(:usage_count)
      end
    end
  end

  describe 'helpers' do
    it 'provides helper methods for views' do
      expect(described_class::Helpers).to respond_to(:feature_status_badge)
      expect(described_class::Helpers).to respond_to(:feature_type_label)
    end

    it 'formats feature status for display' do
      status = described_class::Helpers.feature_status_badge(:active)
      expect(status).to include('active')
    end

    it 'formats feature type for display' do
      type = described_class::Helpers.feature_type_label(:boolean)
      expect(type).to include('Boolean')
    end
  end

  describe 'assets' do
    it 'includes CSS stylesheets' do
      expect(described_class::Engine.assets).to include('magick/admin.css')
    end

    it 'includes JavaScript files' do
      expect(described_class::Engine.assets).to include('magick/admin.js')
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

    it 'allows restricting access by role' do
      described_class.configure do |config|
        config.require_role = :admin
      end
      expect(described_class.config.require_role).to eq(:admin)
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
