# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Versioning do
  let(:registry) { Magick.default_adapter_registry }
  let(:versioning) { described_class.new(registry) }

  before do
    Magick.register_feature(:v_demo)
    Magick[:v_demo].enable
  end

  describe '#save_version' do
    it 'assigns sequential versions starting at 1' do
      v1 = versioning.save_version(:v_demo)
      v2 = versioning.save_version(:v_demo)
      expect(v1.version).to eq(1)
      expect(v2.version).to eq(2)
    end

    it 'stores the feature snapshot for later rollback' do
      versioning.save_version(:v_demo)
      versions = versioning.get_versions(:v_demo)
      expect(versions.first.feature_data[:name]).to eq('v_demo')
    end
  end

  describe '#get_versions' do
    it 'returns a snapshot so callers iterating do not race with concurrent save_version calls' do
      versioning.save_version(:v_demo)
      snapshot = versioning.get_versions(:v_demo)
      versioning.save_version(:v_demo)
      expect(snapshot.size).to eq(1)
    end
  end

  describe 'concurrency' do
    it 'never assigns the same version number twice when many threads save concurrently' do
      threads = 10.times.map do
        Thread.new { 5.times { versioning.save_version(:v_demo) } }
      end
      threads.each(&:join)

      versions = versioning.get_versions(:v_demo).map(&:version)
      expect(versions.sort).to eq((1..50).to_a)
    end
  end

  describe '#rollback' do
    it 'returns false when the requested version does not exist' do
      expect(versioning.rollback(:v_demo, 999)).to be false
    end

    it 'restores the stored value for an existing version' do
      Magick[:v_demo].set_value(true)
      versioning.save_version(:v_demo)
      Magick[:v_demo].set_value(false)
      expect(versioning.rollback(:v_demo, 1)).to be true
      expect(Magick[:v_demo].enabled?).to be true
    end
  end
end
