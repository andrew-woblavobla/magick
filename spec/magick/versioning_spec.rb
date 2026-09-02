# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Versioning do
  let(:registry) { Magick.default_adapter_registry }
  let(:versioning) { described_class.new(registry) }

  before do
    Magick.register_feature(:v_demo)
  end

  describe 'automatic versioning' do
    it 'creates a version for every mutation, under its real action name' do
      Magick[:v_demo].enable
      Magick[:v_demo].disable

      versions = Magick.versioning.get_versions(:v_demo)
      expect(versions.map(&:version)).to eq([1, 2])
      expect(versions.map(&:action)).to eq(%w[enable disable])
    end

    it 'snapshots targeting changes' do
      Magick[:v_demo].enable_for_user(42)

      version = Magick.versioning.get_versions(:v_demo).last
      expect(version.action).to eq('enable_for_user')
      expect(version.feature_data[:targeting][:user]).to eq(['42'])
    end

    it 'does not alias live targeting into previously stored snapshots' do
      Magick[:v_demo].enable_for_user(1)
      Magick[:v_demo].enable_for_user(2)

      versions = Magick.versioning.get_versions(:v_demo)
      expect(versions.first.feature_data[:targeting][:user]).to eq(['1'])
      expect(versions.last.feature_data[:targeting][:user]).to eq(%w[1 2])
    end

    it 'records nothing while definitions are being applied (boot replay)' do
      Magick.definition_mode { Magick[:v_demo].enable }
      expect(Magick.versioning.get_versions(:v_demo)).to be_empty
      expect(Magick[:v_demo].enabled?).to be true
    end
  end

  describe '#save_version' do
    it 'assigns sequential versions starting at 1 and marks them manual' do
      v1 = versioning.save_version(:v_demo)
      v2 = versioning.save_version(:v_demo)
      expect(v1.version).to eq(1)
      expect(v2.version).to eq(2)
      expect(v1.action).to eq('manual')
    end

    it 'stores the feature snapshot for later rollback' do
      versioning.save_version(:v_demo)
      versions = versioning.get_versions(:v_demo)
      expect(versions.first.feature_data[:name]).to eq('v_demo')
    end

    it 'continues numbering after automatically recorded versions' do
      Magick[:v_demo].enable
      expect(Magick.versioning.save_version(:v_demo).version).to eq(2)
    end
  end

  describe 'persistence' do
    it 'shares history through the adapters, so a fresh instance sees prior versions' do
      versioning.save_version(:v_demo)
      versioning.save_version(:v_demo)

      fresh = described_class.new(registry)
      expect(fresh.get_versions(:v_demo).map(&:version)).to eq([1, 2])
    end

    it 'keeps version history out of the feature keys returned by all_features' do
      versioning.save_version(:v_demo)
      expect(registry.all_features).to all(satisfy { |f| !f.start_with?(described_class::STORE_PREFIX) })
    end
  end

  describe 'retention' do
    it 'caps the hot window at max_versions, pruning the oldest' do
      capped = described_class.new(registry, max_versions: 3)
      5.times { capped.save_version(:v_demo) }
      expect(capped.get_versions(:v_demo).map(&:version)).to eq([3, 4, 5])
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

    it 'never assigns the same number twice when two versioning instances share one store' do
      other = described_class.new(registry)
      threads = [versioning, other].flat_map do |instance|
        5.times.map { Thread.new { instance.save_version(:v_demo) } }
      end
      threads.each(&:join)

      versions = versioning.get_versions(:v_demo).map(&:version)
      expect(versions.sort).to eq((1..10).to_a)
    end
  end

  describe 'history written by 1.5.0' do
    let(:store_key) { "#{described_class::STORE_PREFIX}v_demo" }
    let(:legacy_window) do
      [1, 2, 3].map do |number|
        {
          'version' => number,
          'feature_data' => { 'name' => 'v_demo', 'value' => number.odd?, 'targeting' => {} },
          'timestamp' => Time.now.iso8601,
          'created_by' => nil,
          'action' => 'set_value'
        }
      end
    end

    before do
      # 1.5.0 wrote the whole hot window as one JSON list under 'versions'.
      registry.memory_adapter.set(store_key, 'versions', legacy_window)
    end

    it 'still reads snapshots stored as the old single-window blob' do
      expect(versioning.get_versions(:v_demo).map(&:version)).to eq([1, 2, 3])
    end

    it 'continues numbering above them instead of overwriting them' do
      expect(versioning.save_version(:v_demo).version).to eq(4)
      expect(versioning.get_versions(:v_demo).map(&:version)).to eq([1, 2, 3, 4])
    end

    it 'rolls back to a snapshot written before the upgrade' do
      Magick.versioning = versioning
      expect(versioning.rollback(:v_demo, 2)).to be true
      expect(Magick[:v_demo].enabled?).to be false
    end

    it 'migrates the blob to one key per version on the next append' do
      versioning.save_version(:v_demo)

      data = registry.memory_adapter.get_all_data(store_key)
      expect(data.keys).to include('version_1', 'version_2', 'version_3', 'version_4')
      expect(data['versions']).to eq([])
      expect(versioning.get_versions(:v_demo).map(&:version)).to eq([1, 2, 3, 4])
    end
  end

  describe '#rollback' do
    it 'returns false when the requested version does not exist' do
      expect(Magick.versioning.rollback(:v_demo, 999)).to be false
    end

    it 'restores the stored value for an existing version' do
      Magick[:v_demo].set_value(true)
      Magick[:v_demo].set_value(false)

      expect(Magick.versioning.rollback(:v_demo, 1)).to be true
      expect(Magick[:v_demo].enabled?).to be true
    end

    it 'restores false values (falsy snapshot regression)' do
      Magick[:v_demo].set_value(false)
      Magick[:v_demo].set_value(true)

      expect(Magick.versioning.rollback(:v_demo, 1)).to be true
      expect(Magick[:v_demo].enabled?).to be false
    end

    it 'replaces targeting wholesale instead of merging additively' do
      Magick[:v_demo].enable_for_user(1)
      Magick[:v_demo].enable_for_user(2)
      Magick[:v_demo].exclude_user(3)

      Magick.versioning.rollback(:v_demo, 1)

      targeting = Magick.features['v_demo'].instance_variable_get(:@targeting)
      expect(targeting[:user]).to eq(['1'])
      expect(targeting[:excluded_users]).to be_nil
    end

    it 'restores status' do
      Magick[:v_demo].set_value(true)
      Magick[:v_demo].set_status(:inactive)

      Magick.versioning.rollback(:v_demo, 1)
      expect(Magick.features['v_demo'].status).to eq(:active)
    end

    it 'records the rollback itself as a new version instead of rewriting history' do
      Magick[:v_demo].set_value(true)
      Magick[:v_demo].set_value(false)

      Magick.versioning.rollback(:v_demo, 1)

      versions = Magick.versioning.get_versions(:v_demo)
      expect(versions.map(&:version)).to eq([1, 2, 3])
      expect(versions.last.action).to eq('rollback')
    end
  end
end
