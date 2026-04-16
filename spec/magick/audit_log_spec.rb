# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::AuditLog do
  let(:log) { described_class.new(nil, max_entries: 5) }

  it 'appends entries and returns the most recent first via limit' do
    5.times { |i| log.log(:demo, :set_value, changes: { value: i }) }
    expect(log.entries(limit: 3).map(&:changes)).to eq([{ value: 2 }, { value: 3 }, { value: 4 }])
  end

  it 'evicts the oldest entries once the cap is exceeded' do
    10.times { |i| log.log(:demo, :set_value, changes: { value: i }) }
    expect(log.size).to eq(5)
    expect(log.entries(limit: 10).first.changes).to eq({ value: 5 })
    expect(log.entries(limit: 10).last.changes).to eq({ value: 9 })
  end

  it 'defaults to DEFAULT_MAX_ENTRIES when no cap is supplied' do
    default_log = described_class.new
    expect(default_log.max_entries).to eq(Magick::AuditLog::DEFAULT_MAX_ENTRIES)
  end

  it 'filters by feature_name' do
    log.log(:a, :touch)
    log.log(:b, :touch)
    log.log(:a, :touch)
    expect(log.entries(feature_name: :a).size).to eq(2)
  end
end
