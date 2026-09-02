# frozen_string_literal: true

require 'spec_helper'

# NOTE: this file exercises a Magick::Targeting::* strategy object. Nothing outside
# lib/magick/targeting/ constructs these classes — Feature evaluates every rule inline,
# so passing here says nothing about what a flag returns. Behavioural coverage of the
# real evaluation path lives in spec/magick/targeting/evaluation_spec.rb. These specs
# stay until the fate of the strategy classes is decided (audit-1-5-1 issue 01).
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
