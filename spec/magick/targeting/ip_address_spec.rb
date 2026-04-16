# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Feature#enable_for_ip_addresses' do
  # IP targeting acts as a gate: when set, requests from other IPs are
  # blocked even if inclusion targeting (user/group/role) matches.
  it 'blocks a user whose IP is not in the allow-list' do
    Magick.register_feature(:ip_demo)
    Magick[:ip_demo].enable_for_user(1)
    Magick[:ip_demo].enable_for_ip_addresses('10.0.0.0/24')
    expect(Magick[:ip_demo].enabled?(user_id: 1, ip_address: '192.168.1.1')).to be false
  end

  it 'allows a user whose IP is in the allow-list' do
    Magick.register_feature(:ip_demo2)
    Magick[:ip_demo2].enable_for_user(1)
    Magick[:ip_demo2].enable_for_ip_addresses('10.0.0.0/24')
    expect(Magick[:ip_demo2].enabled?(user_id: 1, ip_address: '10.0.0.5')).to be true
  end

  it 'stores IPs as a flat array of strings (not a stringified nested array)' do
    Magick.register_feature(:ip_demo3)
    Magick[:ip_demo3].enable_for_ip_addresses(['10.0.0.1', '192.168.1.0/24'])
    targeting = Magick[:ip_demo3].send(:targeting)
    expect(targeting[:ip_address]).to contain_exactly('10.0.0.1', '192.168.1.0/24')
  end
end

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
