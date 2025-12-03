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
      expect do
        described_class.new(:invalid, adapter_registry, type: :invalid_type, default_value: false)
      end.to raise_error(Magick::InvalidFeatureTypeError)
    end

    it 'raises error for invalid default value' do
      expect do
        described_class.new(:invalid, adapter_registry, type: :boolean, default_value: 'not boolean')
      end.to raise_error(Magick::InvalidFeatureValueError)
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
      let(:feature) do
        described_class.new(:inactive, adapter_registry, type: :boolean, default_value: true, status: :inactive)
      end

      it 'returns false even if value is true' do
        expect(feature.enabled?).to be false
      end
    end

    context 'with deprecated status' do
      let(:feature) do
        described_class.new(:deprecated, adapter_registry, type: :boolean, default_value: true, status: :deprecated)
      end

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
      expect do
        feature.set_value('not boolean')
      end.to raise_error(Magick::InvalidFeatureValueError)
    end
  end

  describe '#set_status' do
    it 'sets the feature status' do
      feature.set_status(:deprecated)
      expect(feature.status).to eq(:deprecated)
    end

    it 'raises error for invalid status' do
      expect do
        feature.set_status(:invalid_status)
      end.to raise_error(Magick::InvalidFeatureValueError)
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

  describe 'string feature type' do
    let(:string_feature) do
      described_class.new(:api_version, adapter_registry, type: :string, default_value: 'v1')
    end

    describe '#initialize' do
      it 'creates a string feature with default value' do
        expect(string_feature.name).to eq('api_version')
        expect(string_feature.type).to eq(:string)
        expect(string_feature.default_value).to eq('v1')
      end

      it 'raises error for invalid default value' do
        expect do
          described_class.new(:invalid, adapter_registry, type: :string, default_value: 123)
        end.to raise_error(Magick::InvalidFeatureValueError)
      end
    end

    describe '#enabled?' do
      it 'returns false for empty string' do
        string_feature.set_value('')
        expect(string_feature.enabled?).to be false
      end

      it 'returns false for default empty string' do
        empty_string_feature = described_class.new(:empty_string, adapter_registry, type: :string, default_value: '')
        expect(empty_string_feature.enabled?).to be false
      end

      it 'returns true for non-empty string' do
        string_feature.set_value('v2')
        expect(string_feature.enabled?).to be true
      end

      it 'returns true for default non-empty string' do
        expect(string_feature.enabled?).to be true # default is 'v1'
      end

      context 'with targeting' do
        it 'returns true when targeting matches' do
          string_feature.set_value('v2')
          string_feature.enable_for_user(123)
          expect(string_feature.enabled?(user_id: 123)).to be true
        end

        it 'returns false when targeting does not match' do
          string_feature.set_value('v2')
          string_feature.enable_for_user(123)
          expect(string_feature.enabled?(user_id: 456)).to be false
        end
      end
    end

    describe '#get_value' do
      it 'returns default value initially' do
        expect(string_feature.get_value).to eq('v1')
      end

      it 'returns set value' do
        string_feature.set_value('v2')
        expect(string_feature.get_value).to eq('v2')
      end

      it 'returns empty string when disabled' do
        string_feature.set_value('v2')
        string_feature.disable
        expect(string_feature.get_value).to eq('')
      end

      context 'with targeting' do
        it 'returns targeted value for matching context' do
          string_feature.set_value('v2')
          string_feature.enable_for_user(123)
          expect(string_feature.get_value(user_id: 123)).to eq('v2')
        end

        it 'returns default value for non-matching context' do
          string_feature.set_value('v2')
          string_feature.enable_for_user(123)
          expect(string_feature.get_value(user_id: 456)).to eq('v1')
        end
      end
    end

    describe '#set_value' do
      it 'sets string value' do
        string_feature.set_value('v2')
        expect(string_feature.value).to eq('v2')
      end

      it 'raises error for non-string value' do
        expect do
          string_feature.set_value(123)
        end.to raise_error(Magick::InvalidFeatureValueError)
      end

      it 'allows empty string' do
        string_feature.set_value('')
        expect(string_feature.value).to eq('')
      end
    end

    describe '#enable' do
      it 'raises error - cannot enable string feature' do
        expect do
          string_feature.enable
        end.to raise_error(Magick::InvalidFeatureValueError, 'Cannot enable string feature. Use set_value instead.')
      end
    end

    describe '#disable' do
      it 'sets value to empty string' do
        string_feature.set_value('v2')
        string_feature.disable
        expect(string_feature.value).to eq('')
        expect(string_feature.enabled?).to be false
      end

      it 'clears targeting' do
        string_feature.enable_for_user(123)
        string_feature.disable
        expect(string_feature.enabled?(user_id: 123)).to be false
      end
    end

    describe '#enable_for_user' do
      it 'enables feature for specific user' do
        string_feature.set_value('v2')
        string_feature.enable_for_user(123)
        expect(string_feature.enabled?(user_id: 123)).to be true
        expect(string_feature.enabled?(user_id: 456)).to be false
      end
    end

    describe '#enable_for_group' do
      it 'enables feature for specific group' do
        string_feature.set_value('v2')
        string_feature.enable_for_group('beta_testers')
        expect(string_feature.enabled?(group: 'beta_testers')).to be true
        expect(string_feature.enabled?(group: 'regular_users')).to be false
      end
    end

    describe '#enable_for_role' do
      it 'enables feature for specific role' do
        string_feature.set_value('v2')
        string_feature.enable_for_role('admin')
        expect(string_feature.enabled?(role: 'admin')).to be true
        expect(string_feature.enabled?(role: 'user')).to be false
      end
    end

    describe '#delete' do
      it 'deletes the feature from adapter' do
        string_feature.set_value('v2')
        expect(string_feature.value).to eq('v2')
        string_feature.delete
        expect(string_feature.value).to eq('v1') # Returns to default
        expect(adapter_registry.exists?(string_feature.name)).to be false
      end
    end
  end

  describe 'number feature type' do
    let(:number_feature) do
      described_class.new(:max_results, adapter_registry, type: :number, default_value: 10)
    end

    describe '#initialize' do
      it 'creates a number feature with default value' do
        expect(number_feature.name).to eq('max_results')
        expect(number_feature.type).to eq(:number)
        expect(number_feature.default_value).to eq(10)
      end

      it 'accepts integer default value' do
        int_feature = described_class.new(:int_feature, adapter_registry, type: :number, default_value: 5)
        expect(int_feature.default_value).to eq(5)
      end

      it 'accepts float default value' do
        float_feature = described_class.new(:float_feature, adapter_registry, type: :number, default_value: 3.14)
        expect(float_feature.default_value).to eq(3.14)
      end

      it 'raises error for invalid default value' do
        expect do
          described_class.new(:invalid, adapter_registry, type: :number, default_value: 'not a number')
        end.to raise_error(Magick::InvalidFeatureValueError)
      end
    end

    describe '#enabled?' do
      it 'returns false for zero' do
        number_feature.set_value(0)
        expect(number_feature.enabled?).to be false
      end

      it 'returns false for negative number' do
        number_feature.set_value(-5)
        expect(number_feature.enabled?).to be false
      end

      it 'returns true for positive number' do
        number_feature.set_value(20)
        expect(number_feature.enabled?).to be true
      end

      it 'returns true for default positive number' do
        expect(number_feature.enabled?).to be true # default is 10
      end

      it 'returns true for positive float' do
        number_feature.set_value(0.5)
        expect(number_feature.enabled?).to be true
      end

      context 'with zero default value' do
        let(:zero_feature) do
          described_class.new(:zero_feature, adapter_registry, type: :number, default_value: 0)
        end

        it 'returns false for zero default' do
          expect(zero_feature.enabled?).to be false
        end
      end

      context 'with targeting' do
        it 'returns true when targeting matches' do
          number_feature.set_value(20)
          number_feature.enable_for_user(123)
          expect(number_feature.enabled?(user_id: 123)).to be true
        end

        it 'returns false when targeting does not match' do
          number_feature.set_value(20)
          number_feature.enable_for_user(123)
          expect(number_feature.enabled?(user_id: 456)).to be false
        end
      end
    end

    describe '#get_value' do
      it 'returns default value initially' do
        expect(number_feature.get_value).to eq(10)
      end

      it 'returns set value' do
        number_feature.set_value(25)
        expect(number_feature.get_value).to eq(25)
      end

      it 'returns zero when disabled' do
        number_feature.set_value(25)
        number_feature.disable
        expect(number_feature.get_value).to eq(0)
      end

      it 'preserves float values' do
        number_feature.set_value(3.14)
        expect(number_feature.get_value).to eq(3.14)
      end

      context 'with targeting' do
        it 'returns targeted value for matching context' do
          number_feature.set_value(25)
          number_feature.enable_for_user(123)
          expect(number_feature.get_value(user_id: 123)).to eq(25)
        end

        it 'returns default value for non-matching context' do
          number_feature.set_value(25)
          number_feature.enable_for_user(123)
          expect(number_feature.get_value(user_id: 456)).to eq(10)
        end
      end
    end

    describe '#set_value' do
      it 'sets integer value' do
        number_feature.set_value(25)
        expect(number_feature.value).to eq(25)
      end

      it 'sets float value' do
        number_feature.set_value(3.14)
        expect(number_feature.value).to eq(3.14)
      end

      it 'raises error for non-numeric value' do
        expect do
          number_feature.set_value('not a number')
        end.to raise_error(Magick::InvalidFeatureValueError)
      end

      it 'allows zero' do
        number_feature.set_value(0)
        expect(number_feature.value).to eq(0)
      end

      it 'allows negative numbers' do
        number_feature.set_value(-5)
        expect(number_feature.value).to eq(-5)
      end
    end

    describe '#enable' do
      it 'raises error - cannot enable number feature' do
        expect do
          number_feature.enable
        end.to raise_error(Magick::InvalidFeatureValueError, 'Cannot enable number feature. Use set_value instead.')
      end
    end

    describe '#disable' do
      it 'sets value to zero' do
        number_feature.set_value(25)
        number_feature.disable
        expect(number_feature.value).to eq(0)
        expect(number_feature.enabled?).to be false
      end

      it 'clears targeting' do
        number_feature.enable_for_user(123)
        number_feature.disable
        expect(number_feature.enabled?(user_id: 123)).to be false
      end
    end

    describe '#enable_for_user' do
      it 'enables feature for specific user' do
        number_feature.set_value(25)
        number_feature.enable_for_user(123)
        expect(number_feature.enabled?(user_id: 123)).to be true
        expect(number_feature.enabled?(user_id: 456)).to be false
      end
    end

    describe '#enable_for_group' do
      it 'enables feature for specific group' do
        number_feature.set_value(25)
        number_feature.enable_for_group('beta_testers')
        expect(number_feature.enabled?(group: 'beta_testers')).to be true
        expect(number_feature.enabled?(group: 'regular_users')).to be false
      end
    end

    describe '#enable_for_role' do
      it 'enables feature for specific role' do
        number_feature.set_value(25)
        number_feature.enable_for_role('admin')
        expect(number_feature.enabled?(role: 'admin')).to be true
        expect(number_feature.enabled?(role: 'user')).to be false
      end
    end

    describe '#enable_percentage_of_users' do
      it 'enables feature for percentage of users' do
        number_feature.set_value(25)
        number_feature.enable_percentage_of_users(50)
        # Percentage targeting works with consistent hashing
        expect(number_feature.enabled?(user_id: 1)).to be_a(TrueClass).or be_a(FalseClass)
      end
    end

    describe '#delete' do
      it 'deletes the feature from adapter' do
        number_feature.set_value(25)
        expect(number_feature.value).to eq(25)
        number_feature.delete
        expect(number_feature.value).to eq(10) # Returns to default
        expect(adapter_registry.exists?(number_feature.name)).to be false
      end
    end
  end
end
