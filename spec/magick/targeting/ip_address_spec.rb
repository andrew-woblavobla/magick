# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Targeting::IpAddress do
  it 'matches a client IP inside the CIDR range' do
    strategy = described_class.new(['10.0.0.0/24'])
    expect(strategy.matches?(ip_address: '10.0.0.5')).to be true
  end

  it 'does not match an IP outside the range' do
    strategy = described_class.new(['10.0.0.0/24'])
    expect(strategy.matches?(ip_address: '10.0.1.5')).to be false
  end

  it 'accepts a single IP (not wrapped in an array)' do
    strategy = described_class.new('127.0.0.1')
    expect(strategy.matches?(ip_address: '127.0.0.1')).to be true
  end

  it 'returns false when context lacks :ip_address' do
    strategy = described_class.new(['10.0.0.0/24'])
    expect(strategy.matches?({})).to be false
  end

  it 'returns false on malformed client IP (does not raise)' do
    strategy = described_class.new(['10.0.0.0/24'])
    expect(strategy.matches?(ip_address: 'not-an-ip')).to be false
  end
end
