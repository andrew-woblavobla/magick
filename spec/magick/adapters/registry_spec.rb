# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Adapters::Registry do
  let(:memory_adapter) { Magick::Adapters::Memory.new }
  let(:registry) { described_class.new(memory_adapter) }

  describe '#get' do
    it 'retrieves from memory adapter' do
      memory_adapter.set(:test_feature, 'value', true)
      expect(registry.get(:test_feature, 'value')).to be true
    end

    it 'returns nil when not found' do
      expect(registry.get(:non_existent, 'value')).to be_nil
    end
  end

  describe '#set' do
    it 'sets value in memory adapter' do
      registry.set(:test_feature, 'value', true)
      expect(memory_adapter.get(:test_feature, 'value')).to be true
    end
  end

  describe '#delete' do
    it 'deletes from memory adapter' do
      registry.set(:test_feature, 'value', true)
      registry.delete(:test_feature)
      expect(registry.exists?(:test_feature)).to be false
    end
  end
end
