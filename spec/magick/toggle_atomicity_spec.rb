# frozen_string_literal: true

require 'spec_helper'

# The global toggles — Feature#enable / #disable and the bulk helpers built on
# them — either go through completely or change nothing at all, and the bulk
# helpers say what they did.
RSpec.describe 'Global toggles' do
  let(:audit) { Magick::AuditLog.new }
  # The backend the registered features actually read and write through.
  let(:backend) { Magick.default_adapter_registry }

  before { Magick.audit_log = audit }

  describe 'Magick::Feature#enable on a feature that has no "on"' do
    let(:string_feature) { Magick.register_feature(:api_version, type: :string, default_value: 'v1') }
    let(:number_feature) { Magick.register_feature(:page_size, type: :number, default_value: 10) }

    it 'raises on a string feature without touching its targeting' do
      string_feature.set_value('v2')
      string_feature.enable_for_user(123)

      expect { string_feature.enable }
        .to raise_error(Magick::InvalidFeatureValueError, 'Cannot enable string feature. Use set_value instead.')

      expect(string_feature.targeting).to eq(user: ['123'])
      expect(string_feature.get_value(user_id: 123)).to eq('v2')
      expect(string_feature.enabled?(user_id: 123)).to be true
    end

    it 'raises on a number feature without touching its targeting' do
      number_feature.set_value(50)
      number_feature.enable_for_group('beta')

      expect { number_feature.enable }
        .to raise_error(Magick::InvalidFeatureValueError, 'Cannot enable number feature. Use set_value instead.')

      expect(number_feature.targeting).to eq(group: ['beta'])
      expect(number_feature.get_value(group: 'beta')).to eq(50)
    end

    it 'leaves the backend copy of the targeting untouched' do
      string_feature.enable_for_user(123)

      expect { string_feature.enable }.to raise_error(Magick::InvalidFeatureValueError)

      # Read it back rather than trusting the in-process copy.
      expect(backend.get('api_version', 'targeting')).to eq('user' => ['123'])
      reloaded = Magick::Feature.new(:api_version, backend, type: :string, default_value: 'v1')
      expect(reloaded.targeting).to eq(user: ['123'])
      expect(reloaded.enabled?(user_id: 123)).to be true
    end

    it 'records neither an audit entry nor a version for the call that raised' do
      string_feature.enable_for_user(123)
      actions_before = audit.entries(feature_name: :api_version).map(&:action)
      versions_before = Magick.versioning.get_versions(:api_version).length

      expect { string_feature.enable }.to raise_error(Magick::InvalidFeatureValueError)

      expect(audit.entries(feature_name: :api_version).map(&:action)).to eq(actions_before)
      expect(Magick.versioning.get_versions(:api_version).length).to eq(versions_before)
    end
  end

  describe 'Magick.bulk_disable' do
    it 'switches a flag off for the user it was enabled for' do
      Magick.register_feature(:checkout, type: :boolean, default_value: false)
      Magick[:checkout].enable_for_user(123)
      expect(Magick.enabled?(:checkout, user_id: 123)).to be true

      Magick.bulk_disable([:checkout])

      expect(Magick.enabled?(:checkout, user_id: 123)).to be false
    end

    it 'clears targeting in the backend, not just the stored value' do
      Magick.register_feature(:promo, type: :boolean, default_value: false)
      Magick[:promo].enable_percentage_of_users(100)
      Magick[:promo].enable_for_group('beta')
      expect(Magick.enabled?(:promo, user_id: 1)).to be true

      Magick.bulk_disable([:promo])

      expect(Magick[:promo].targeting).to be_empty
      expect(backend.get('promo', 'targeting')).to be_empty
      expect(Magick.enabled?(:promo, user_id: 1)).to be false
      expect(Magick.enabled?(:promo, group: 'beta')).to be false
    end

    it 'disables string and number features instead of passing over them' do
      Magick.register_feature(:api_version, type: :string, default_value: 'v1')
      Magick.register_feature(:page_size, type: :number, default_value: 10)
      Magick[:api_version].set_value('v2')
      Magick[:page_size].set_value(50)

      result = Magick.bulk_disable(%i[api_version page_size])

      expect(result).to be_complete
      expect(result.skipped_reasons).to be_empty
      expect(Magick[:api_version].value).to eq('')
      expect(Magick[:page_size].value).to eq(0)
    end
  end

  describe 'Magick.bulk_enable' do
    it 'enables globally, clearing targeting the way Feature#enable does' do
      Magick.register_feature(:checkout, type: :boolean, default_value: false)
      Magick[:checkout].enable_for_user(123)

      Magick.bulk_enable([:checkout])

      expect(Magick.enabled?(:checkout, user_id: 456)).to be true
      expect(Magick[:checkout].targeting).to be_empty
      expect(backend.get('checkout', 'targeting')).to be_empty
    end

    it 'names the features it could not enable' do
      Magick.register_feature(:checkout, type: :boolean, default_value: false)
      Magick.register_feature(:api_version, type: :string, default_value: 'v1')
      Magick.register_feature(:page_size, type: :number, default_value: 10)

      result = Magick.bulk_enable(%i[checkout api_version page_size])

      expect(result).not_to be_complete
      expect(result.changed.map(&:name)).to eq(['checkout'])
      expect(result.skipped.map(&:name)).to eq(%w[api_version page_size])
      expect(result.skipped_reasons).to eq(
        'api_version' => 'cannot enable a string feature; use set_value',
        'page_size' => 'cannot enable a number feature; use set_value'
      )
    end

    it 'still enables what it can, and leaves the rest exactly as it was' do
      Magick.register_feature(:checkout, type: :boolean, default_value: false)
      Magick.register_feature(:api_version, type: :string, default_value: 'v1')
      Magick[:api_version].set_value('v2')
      Magick[:api_version].enable_for_user(123)

      Magick.bulk_enable(%i[checkout api_version])

      expect(Magick.enabled?(:checkout)).to be true
      expect(Magick[:api_version].get_value(user_id: 123)).to eq('v2')
      expect(backend.get('api_version', 'targeting')).to eq('user' => ['123'])
    end
  end

  describe 'the value a bulk helper returns' do
    before do
      Magick.register_feature(:first, type: :boolean, default_value: false)
      Magick.register_feature(:second, type: :boolean, default_value: false)
    end

    it 'still iterates as the array of features these helpers used to return' do
      result = Magick.bulk_enable(%i[first second])

      expect(result.map(&:name)).to eq(%w[first second])
      expect(result.to_a).to all(be_a(Magick::Feature))
      expect(result.first.name).to eq('first')
      expect(result.size).to eq(2)
      expect(result[1].name).to eq('second')
    end

    it 'reports a clean run as complete' do
      expect(Magick.bulk_disable(%i[first second])).to be_complete
    end
  end
end
