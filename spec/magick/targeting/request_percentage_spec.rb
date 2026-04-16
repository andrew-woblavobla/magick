# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Targeting::RequestPercentage do
  it 'matches 100% of requests when percentage is 100' do
    strategy = described_class.new(100)
    100.times { expect(strategy.matches?({})).to be true }
  end

  it 'matches 0% of requests when percentage is 0' do
    strategy = described_class.new(0)
    100.times { expect(strategy.matches?({})).to be false }
  end

  it 'matches roughly the configured percentage over many trials' do
    strategy = described_class.new(50)
    matches = 10_000.times.count { strategy.matches?({}) }
    expect(matches).to be_within(500).of(5000)
  end
end
