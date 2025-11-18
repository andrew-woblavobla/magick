# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Adapters::Memory do
  let(:adapter) { described_class.new }

  describe '#get and #set' do
    it 'stores and retrieves values' do
      adapter.set(:test_feature, 'value', true)
      expect(adapter.get(:test_feature, 'value')).to be true
    end

    it 'returns nil for non-existent keys' do
      expect(adapter.get(:non_existent, 'value')).to be_nil
    end
  end

  describe '#delete' do
    it 'deletes a feature' do
      adapter.set(:test_feature, 'value', true)
      adapter.delete(:test_feature)
      expect(adapter.exists?(:test_feature)).to be false
    end
  end

  describe '#exists?' do
    it 'returns true for existing features' do
      adapter.set(:test_feature, 'value', true)
      expect(adapter.exists?(:test_feature)).to be true
    end

    it 'returns false for non-existent features' do
      expect(adapter.exists?(:non_existent)).to be false
    end
  end

  describe '#all_features' do
    it 'returns all feature names' do
      adapter.set(:feature1, 'value', true)
      adapter.set(:feature2, 'value', false)
      expect(adapter.all_features).to include('feature1', 'feature2')
    end
  end

  describe 'thread safety' do
    it 'handles concurrent access' do
      threads = []
      10.times do |i|
        threads << Thread.new do
          adapter.set("feature_#{i}", 'value', i)
        end
      end
      threads.each(&:join)

      expect(adapter.all_features.length).to eq(10)
    end
  end
end
