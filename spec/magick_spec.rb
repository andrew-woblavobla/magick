# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick do
  describe '.register_feature' do
    it 'registers a new feature' do
      feature = Magick.register_feature(:test_feature, type: :boolean, default_value: false)
      expect(feature).to be_a(Magick::Feature)
      expect(Magick.features['test_feature']).to eq(feature)
    end
  end

  describe '.enabled?' do
    context 'with boolean feature' do
      before do
        Magick.register_feature(:test_bool, type: :boolean, default_value: false)
      end

      it 'returns false by default' do
        expect(Magick.enabled?(:test_bool)).to be false
      end

      it 'returns true when feature is enabled' do
        feature = Magick[:test_bool]
        feature.set_value(true)
        expect(Magick.enabled?(:test_bool)).to be true
      end
    end

    context 'with user targeting' do
      before do
        Magick.register_feature(:user_feature, type: :boolean, default_value: false)
      end

      it 'enables feature for specific user' do
        feature = Magick[:user_feature]
        feature.enable_for_user(123)
        expect(Magick.enabled?(:user_feature, user_id: 123)).to be true
        expect(Magick.enabled?(:user_feature, user_id: 456)).to be false
      end
    end

    context 'with percentage targeting' do
      before do
        Magick.register_feature(:percentage_feature, type: :boolean, default_value: false)
      end

      it 'enables feature for percentage of users consistently' do
        feature = Magick[:percentage_feature]
        feature.enable_percentage_of_users(100)
        expect(Magick.enabled?(:percentage_feature, user_id: 123)).to be true
      end
    end

    context 'with tag targeting' do
      before do
        Magick.register_feature(:tag_feature, type: :boolean, default_value: false)
      end

      it 'enables feature for specific tags' do
        feature = Magick[:tag_feature]
        feature.set_value(true)
        feature.enable_for_tag('premium')
        expect(Magick.enabled?(:tag_feature, tags: ['premium'])).to be true
        expect(Magick.enabled?(:tag_feature, tags: ['free'])).to be false
      end

      it 'enables feature when any tag matches' do
        feature = Magick[:tag_feature]
        feature.set_value(true)
        feature.enable_for_tag('premium')
        feature.enable_for_tag('beta')
        expect(Magick.enabled?(:tag_feature, tags: ['premium', 'other'])).to be true
        expect(Magick.enabled?(:tag_feature, tags: ['beta'])).to be true
      end

      it 'works with user object that has tags' do
        mock_user = double('User', id: 123, tags: [double(id: 1), double(id: 2)])
        feature = Magick[:tag_feature]
        feature.set_value(true)
        feature.enable_for_tag('1')
        expect(Magick.enabled_for?(:tag_feature, mock_user)).to be true
      end
    end
  end

  describe '.disabled?' do
    before do
      Magick.register_feature(:test_disabled, type: :boolean, default_value: false)
    end

    it 'returns true when feature is disabled' do
      expect(Magick.disabled?(:test_disabled)).to be true
    end

    it 'returns false when feature is enabled' do
      feature = Magick[:test_disabled]
      feature.set_value(true)
      expect(Magick.disabled?(:test_disabled)).to be false
    end
  end

  describe '.reset!' do
    it 'clears all features' do
      Magick.register_feature(:test_reset, type: :boolean, default_value: false)
      expect(Magick.features).not_to be_empty
      Magick.reset!
      expect(Magick.features).to be_empty
    end
  end

  describe 'DSL methods' do
    before do
      Magick.register_feature(:dsl_tag_feature, type: :boolean, default_value: false)
    end

    describe 'enable_for_tag' do
      it 'enables feature for tag via DSL' do
        enable_for_tag(:dsl_tag_feature, 'premium')
        expect(Magick.enabled?(:dsl_tag_feature, tags: ['premium'])).to be true
        expect(Magick.enabled?(:dsl_tag_feature, tags: ['free'])).to be false
      end

      it 'works with multiple tags' do
        enable_for_tag(:dsl_tag_feature, 'premium')
        enable_for_tag(:dsl_tag_feature, 'beta')
        expect(Magick.enabled?(:dsl_tag_feature, tags: ['premium'])).to be true
        expect(Magick.enabled?(:dsl_tag_feature, tags: ['beta'])).to be true
      end
    end
  end
end
