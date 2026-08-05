# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Change recording' do
  let(:audit) { Magick::AuditLog.new }

  before do
    Magick.audit_log = audit
    Magick.register_feature(:cr_demo)
  end

  describe 'audit coverage' do
    it 'logs enable under its real action name, exactly once' do
      Magick[:cr_demo].enable
      expect(audit.entries(feature_name: :cr_demo).map(&:action)).to eq(['enable'])
    end

    it 'logs disable under its real action name, exactly once' do
      Magick[:cr_demo].disable
      expect(audit.entries(feature_name: :cr_demo).map(&:action)).to eq(['disable'])
    end

    it 'still logs direct set_value calls as set_value' do
      Magick[:cr_demo].set_value(true)
      entry = audit.entries(feature_name: :cr_demo).last
      expect(entry.action).to eq('set_value')
      expect(entry.changes[:value][:to]).to be true
    end

    it 'logs targeting mutations' do
      Magick[:cr_demo].enable_for_user(42)
      Magick[:cr_demo].exclude_user(43)
      Magick[:cr_demo].enable_percentage_of_users(25)

      actions = audit.entries(feature_name: :cr_demo).map(&:action)
      expect(actions).to eq(%w[enable_for_user exclude_user enable_percentage_of_users])
    end

    it 'logs set_status, set_group and delete' do
      Magick[:cr_demo].set_status(:inactive)
      Magick[:cr_demo].set_group('checkout')
      Magick[:cr_demo].delete

      actions = audit.entries(feature_name: :cr_demo).map(&:action)
      expect(actions).to eq(%w[set_status set_group delete])
    end

    it 'does not log anything for a failed mutation' do
      expect { Magick[:cr_demo].set_value('nope') }.to raise_error(Magick::InvalidFeatureValueError)
      expect(audit.entries(feature_name: :cr_demo)).to be_empty
    end
  end

  describe 'actor attribution' do
    it 'stamps audit user_id and version created_by from the ambient actor' do
      Magick.with_actor('admin-7') { Magick[:cr_demo].enable_for_user(1) }

      expect(audit.entries(feature_name: :cr_demo).last.user_id).to eq('admin-7')
      expect(Magick.versioning.get_versions(:cr_demo).last.created_by).to eq('admin-7')
    end

    it 'lets an explicit user_id win over the ambient actor' do
      Magick.with_actor('ambient') { Magick[:cr_demo].set_value(true, user_id: 'explicit') }
      expect(audit.entries(feature_name: :cr_demo).last.user_id).to eq('explicit')
    end

    it 'restores the previous actor after the block' do
      Magick.with_actor('outer') do
        Magick.with_actor('inner') {}
        expect(Magick.current_actor).to eq('outer')
      end
      expect(Magick.current_actor).to be_nil
    end
  end

  describe 'definition mode' do
    it 'applies the change but records neither audit entries nor versions' do
      Magick.definition_mode { Magick[:cr_demo].enable }

      expect(Magick[:cr_demo].enabled?).to be true
      expect(audit.entries(feature_name: :cr_demo)).to be_empty
      expect(Magick.versioning.get_versions(:cr_demo)).to be_empty
    end
  end

  describe 'delete' do
    it 'snapshots the state the feature had before deletion' do
      Magick[:cr_demo].set_value(true)
      Magick[:cr_demo].delete

      last = Magick.versioning.get_versions(:cr_demo).last
      expect(last.action).to eq('delete')
      expect(last.feature_data[:value]).to be true
    end
  end

  describe 'versioning disabled' do
    it 'skips version snapshots but keeps audit entries' do
      Magick.versioning_enabled = false
      Magick[:cr_demo].enable

      expect(Magick.versioning.get_versions(:cr_demo)).to be_empty
      expect(audit.entries(feature_name: :cr_demo).map(&:action)).to eq(['enable'])
    end
  end
end
