# frozen_string_literal: true

require 'spec_helper'

# NOTE: this file exercises a Magick::Targeting::* strategy object. Nothing outside
# lib/magick/targeting/ constructs these classes — Feature evaluates every rule inline,
# so passing here says nothing about what a flag returns. Behavioural coverage of the
# real evaluation path lives in spec/magick/targeting/evaluation_spec.rb. These specs
# stay until the fate of the strategy classes is decided (audit-1-5-1 issue 01).
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
