# frozen_string_literal: true

require 'spec_helper'

# NOTE: this file exercises a Magick::Targeting::* strategy object. Nothing outside
# lib/magick/targeting/ constructs these classes — Feature evaluates every rule inline,
# so passing here says nothing about what a flag returns. Behavioural coverage of the
# real evaluation path lives in spec/magick/targeting/evaluation_spec.rb. These specs
# stay until the fate of the strategy classes is decided (audit-1-5-1 issue 01).
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
