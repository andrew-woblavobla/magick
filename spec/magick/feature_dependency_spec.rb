# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::FeatureDependency do
  before do
    Magick.register_feature(:parent)
    Magick.register_feature(:child)
  end

  describe '.add_dependency' do
    it 'records a dependency between two features' do
      described_class.add_dependency(:child, :parent)
      deps = Magick[:child].instance_variable_get(:@dependencies) || []
      expect(deps).to include('parent')
    end

    it 'is idempotent — adding the same dependency twice does not duplicate' do
      2.times { described_class.add_dependency(:child, :parent) }
      deps = Magick[:child].instance_variable_get(:@dependencies) || []
      expect(deps.count('parent')).to eq(1)
    end
  end

  describe '.remove_dependency' do
    it 'removes a previously added dependency' do
      described_class.add_dependency(:child, :parent)
      described_class.remove_dependency(:child, :parent)
      deps = Magick[:child].instance_variable_get(:@dependencies) || []
      expect(deps).not_to include('parent')
    end
  end

  describe '.check' do
    it 'returns true when every dependency is enabled' do
      Magick[:parent].enable
      described_class.add_dependency(:child, :parent)
      expect(described_class.check(:child)).to be true
    end

    it 'returns false when any dependency is disabled' do
      Magick[:parent].disable
      described_class.add_dependency(:child, :parent)
      expect(described_class.check(:child)).to be false
    end

    it 'returns true for features with no dependencies' do
      expect(described_class.check(:parent)).to be true
    end
  end

  describe 'Feature#enable cascade' do
    it 'refuses to enable when any parent is disabled' do
      Magick[:parent].disable
      Magick[:child].instance_variable_set(:@dependencies, ['parent'])
      expect(Magick[:child].enable).to be false
      expect(Magick[:child].enabled?).to be false
    end

    it 'enables when every parent is already enabled' do
      Magick[:parent].enable
      Magick[:child].instance_variable_set(:@dependencies, ['parent'])
      expect(Magick[:child].enable).to be true
      expect(Magick[:child].enabled?).to be true
    end
  end

  describe 'Feature#disable cascade' do
    it 'disables features that depend on the disabled parent' do
      Magick[:parent].enable
      Magick[:child].instance_variable_set(:@dependencies, ['parent'])
      Magick[:child].enable
      expect(Magick[:child].enabled?).to be true

      Magick[:parent].disable
      expect(Magick[:child].enabled?).to be false
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
