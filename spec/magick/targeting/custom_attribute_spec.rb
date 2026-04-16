# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Targeting::CustomAttribute do
  describe 'equals / eq' do
    it 'matches when the context value is in the allowed set' do
      strategy = described_class.new(:country, %w[US CA], operator: :equals)
      expect(strategy.matches?(country: 'US')).to be true
    end

    it 'does not match when the context value is outside the set' do
      strategy = described_class.new(:country, %w[US CA], operator: :equals)
      expect(strategy.matches?(country: 'DE')).to be false
    end

    it 'coerces the context value to a String and compares against string entries' do
      strategy = described_class.new(:age, %w[25], operator: :equals)
      expect(strategy.matches?(age: 25)).to be true
    end
  end

  describe 'not_equals / ne' do
    it 'matches when the value is not in the list' do
      strategy = described_class.new(:country, %w[US], operator: :not_equals)
      expect(strategy.matches?(country: 'DE')).to be true
    end
  end

  describe 'greater_than / gt' do
    it 'matches when the numeric value exceeds the threshold' do
      strategy = described_class.new(:age, [18], operator: :gt)
      expect(strategy.matches?(age: 21)).to be true
    end

    it 'does not match when the value equals the threshold' do
      strategy = described_class.new(:age, [18], operator: :gt)
      expect(strategy.matches?(age: 18)).to be false
    end

    it 'raises if constructed without values' do
      expect { described_class.new(:age, [], operator: :gt) }.to raise_error(ArgumentError)
    end
  end

  describe 'less_than / lt' do
    it 'matches when the value is below the threshold' do
      strategy = described_class.new(:age, [65], operator: :lt)
      expect(strategy.matches?(age: 30)).to be true
    end
  end

  describe 'in / not_in' do
    it ':in matches membership' do
      strategy = described_class.new(:plan, %w[pro enterprise], operator: :in)
      expect(strategy.matches?(plan: 'pro')).to be true
    end

    it ':not_in excludes membership' do
      strategy = described_class.new(:plan, %w[pro enterprise], operator: :not_in)
      expect(strategy.matches?(plan: 'free')).to be true
    end
  end

  it 'returns false when the context lacks the attribute' do
    strategy = described_class.new(:country, %w[US], operator: :equals)
    expect(strategy.matches?({})).to be false
  end

  it 'accepts string keys in the context hash' do
    strategy = described_class.new(:country, %w[US], operator: :equals)
    expect(strategy.matches?('country' => 'US')).to be true
  end

  it 'returns false for unknown operators' do
    strategy = described_class.new(:country, %w[US], operator: :bogus)
    expect(strategy.matches?(country: 'US')).to be false
  end
end
