# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Targeting::DateRange do
  it 'matches when now is inside [start, end]' do
    strategy = described_class.new(Time.now - 60, Time.now + 60)
    expect(strategy.matches?({})).to be true
  end

  it 'does not match before start' do
    strategy = described_class.new(Time.now + 60, Time.now + 120)
    expect(strategy.matches?({})).to be false
  end

  it 'does not match after end' do
    strategy = described_class.new(Time.now - 120, Time.now - 60)
    expect(strategy.matches?({})).to be false
  end

  it 'accepts string dates and parses them' do
    strategy = described_class.new((Time.now - 60).iso8601, (Time.now + 60).iso8601)
    expect(strategy.matches?({})).to be true
  end
end
