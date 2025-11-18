# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Feature do
  let(:adapter_registry) { Magick::Adapters::Registry.new(Magick::Adapters::Memory.new) }
  let(:feature) { described_class.new(:test_feature, adapter_registry, type: :boolean, default_value: false) }

  describe '#initialize' do
    it 'creates a feature with default values' do
      expect(feature.name).to eq('test_feature')
      expect(feature.type).to eq(:boolean)
      expect(feature.status).to eq(:active)
      expect(feature.default_value).to be false
    end

    it 'raises error for invalid type' do
      expect {
        described_class.new(:invalid, adapter_registry, type: :invalid_type, default_value: false)
      }.to raise_error(Magick::InvalidFeatureTypeError)
    end

    it 'raises error for invalid default value' do
      expect {
        described_class.new(:invalid, adapter_registry, type: :boolean, default_value: 'not boolean')
      }.to raise_error(Magick::InvalidFeatureValueError)
    end
  end

  describe '#enabled?' do
    context 'with boolean feature' do
      it 'returns false by default' do
        expect(feature.enabled?).to be false
      end

      it 'returns true when value is set to true' do
        feature.set_value(true)
        expect(feature.enabled?).to be true
      end
    end

    context 'with inactive status' do
      let(:feature) { described_class.new(:inactive, adapter_registry, type: :boolean, default_value: true, status: :inactive) }

      it 'returns false even if value is true' do
        expect(feature.enabled?).to be false
      end
    end

    context 'with deprecated status' do
      let(:feature) { described_class.new(:deprecated, adapter_registry, type: :boolean, default_value: true, status: :deprecated) }

      it 'returns false by default' do
        expect(feature.enabled?).to be false
      end

      it 'returns true when allow_deprecated is true' do
        expect(feature.enabled?(allow_deprecated: true)).to be true
      end
    end
  end

  describe '#enable_for_user' do
    it 'enables feature for specific user' do
      feature.enable_for_user(123)
      expect(feature.enabled?(user_id: 123)).to be true
      expect(feature.enabled?(user_id: 456)).to be false
    end
  end

  describe '#enable_for_group' do
    it 'enables feature for specific group' do
      feature.enable_for_group('beta_testers')
      expect(feature.enabled?(group: 'beta_testers')).to be true
      expect(feature.enabled?(group: 'regular_users')).to be false
    end
  end

  describe '#enable_for_role' do
    it 'enables feature for specific role' do
      feature.enable_for_role('admin')
      expect(feature.enabled?(role: 'admin')).to be true
      expect(feature.enabled?(role: 'user')).to be false
    end
  end

  describe '#set_value' do
    it 'sets the feature value' do
      feature.set_value(true)
      expect(feature.value).to be true
    end

    it 'raises error for invalid value type' do
      expect {
        feature.set_value('not boolean')
      }.to raise_error(Magick::InvalidFeatureValueError)
    end
  end

  describe '#set_status' do
    it 'sets the feature status' do
      feature.set_status(:deprecated)
      expect(feature.status).to eq(:deprecated)
    end

    it 'raises error for invalid status' do
      expect {
        feature.set_status(:invalid_status)
      }.to raise_error(Magick::InvalidFeatureValueError)
    end
  end

  describe '#delete' do
    it 'deletes the feature from adapter' do
      feature.set_value(true)
      expect(feature.value).to be true
      feature.delete
      # After delete, feature returns to default value
      expect(feature.value).to eq(feature.default_value)
      expect(adapter_registry.exists?(feature.name)).to be false
    end
  end
end
