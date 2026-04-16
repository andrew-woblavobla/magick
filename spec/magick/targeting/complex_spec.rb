# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Targeting::Complex do
  let(:truthy) { instance_double(Magick::Targeting::Base, matches?: true) }
  let(:falsy)  { instance_double(Magick::Targeting::Base, matches?: false) }

  describe ':and / :all operator' do
    it 'matches when every condition matches' do
      strategy = described_class.new([truthy, truthy], operator: :and)
      expect(strategy.matches?({})).to be true
    end

    it 'does not match when any condition fails' do
      strategy = described_class.new([truthy, falsy], operator: :and)
      expect(strategy.matches?({})).to be false
    end
  end

  describe ':or / :any operator' do
    it 'matches when any condition matches' do
      strategy = described_class.new([falsy, truthy], operator: :or)
      expect(strategy.matches?({})).to be true
    end

    it 'does not match when every condition fails' do
      strategy = described_class.new([falsy, falsy], operator: :or)
      expect(strategy.matches?({})).to be false
    end
  end

  it 'does not match an empty condition list (regardless of operator)' do
    strategy = described_class.new([], operator: :and)
    expect(strategy.matches?({})).to be false
  end

  it 'returns false for unknown operators' do
    strategy = described_class.new([truthy], operator: :bogus)
    expect(strategy.matches?({})).to be false
  end

  it 'accepts a single condition (not wrapped in an array)' do
    strategy = described_class.new(truthy, operator: :and)
    expect(strategy.matches?({})).to be true
  end
end
