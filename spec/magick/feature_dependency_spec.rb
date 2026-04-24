# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Feature dependencies (evaluation-only)' do
  before do
    Magick.register_feature(:parent)
    Magick.register_feature(:child)
    Magick[:child].instance_variable_set(:@dependencies, ['parent'])
  end

  describe '#enabled?' do
    it 'returns false when any prerequisite is disabled' do
      Magick[:parent].disable
      Magick[:child].enable
      expect(Magick[:child].enabled?).to be false
    end

    it 'returns true when prerequisites are enabled and the feature is enabled' do
      Magick[:parent].enable
      Magick[:child].enable
      expect(Magick[:child].enabled?).to be true
    end

    it 'treats missing prerequisites as satisfied' do
      Magick[:child].instance_variable_set(:@dependencies, ['does_not_exist'])
      Magick[:child].enable
      expect(Magick[:child].enabled?).to be true
    end
  end

  describe '#enable' do
    it 'allows enabling even when a prerequisite is disabled (state is configuration, not evaluation)' do
      Magick[:parent].disable
      expect(Magick[:child].enable).to be true
      # Configured on, but evaluates off because prerequisite is off
      expect(Magick[:child].enabled?).to be false
    end

    it 'begins evaluating true automatically once the prerequisite is re-enabled' do
      Magick[:parent].disable
      Magick[:child].enable
      expect(Magick[:child].enabled?).to be false

      Magick[:parent].enable
      expect(Magick[:child].enabled?).to be true
    end
  end

  describe '#disable' do
    it 'does not cascade — disabling a prerequisite preserves the dependent feature’s configured state' do
      Magick[:parent].enable
      Magick[:child].enable

      Magick[:parent].disable

      # Configured state preserved (value unchanged), but evaluates off.
      expect(Magick[:child].get_value).to be true
      expect(Magick[:child].enabled?).to be false

      # Restoring the prerequisite restores evaluation without re-toggling the dependent.
      Magick[:parent].enable
      expect(Magick[:child].enabled?).to be true
    end

    it 'does not touch unrelated features' do
      Magick.register_feature(:sibling)
      Magick[:sibling].enable
      Magick[:parent].enable
      Magick[:parent].disable
      expect(Magick[:sibling].enabled?).to be true
    end
  end
end
