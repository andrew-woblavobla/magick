# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::TargetingPayload do
  describe '.normalize' do
    it 'accepts string keys, plural aliases and scalar values' do
      result = described_class.normalize('users' => 3, 'roles' => 'admin', 'tags' => %w[beta])
      expect(result).to eq(user: ['3'], role: ['admin'], tag: ['beta'])
    end

    it 'coerces numeric strings for percentages' do
      result = described_class.normalize(percentage_users: '50', percentage_requests: 12.5)
      expect(result).to eq(percentage_users: 50.0, percentage_requests: 12.5)
    end

    it 'drops keys whose value is nil or an empty list' do
      result = described_class.normalize(user: [], role: nil, tag: ['', ' '])
      expect(result).to eq({})
    end

    it 'deduplicates and strips list values' do
      result = described_class.normalize(user: [3, '3', ' 7 '])
      expect(result).to eq(user: %w[3 7])
    end

    it 'raises on unknown keys' do
      expect { described_class.normalize(bogus: 1) }
        .to raise_error(Magick::InvalidTargetingError, /unknown targeting key: 'bogus'/)
    end

    it 'raises on conflicting aliased keys' do
      expect { described_class.normalize(user: [1], users: [2]) }
        .to raise_error(Magick::InvalidTargetingError, /conflicting targeting keys/)
    end

    it 'rejects variants — they are not part of the wire payload' do
      expect { described_class.normalize(variants: []) }
        .to raise_error(Magick::InvalidTargetingError, /variants/)
    end

    it 'raises on non-hash payloads' do
      expect { described_class.normalize([]) }
        .to raise_error(Magick::InvalidTargetingError, /must be a Hash/)
    end

    it 'raises on out-of-range or non-numeric percentages' do
      expect { described_class.normalize(percentage_users: 150) }
        .to raise_error(Magick::InvalidTargetingError, /within \(0, 100\]/)
      expect { described_class.normalize(percentage_users: 0) }
        .to raise_error(Magick::InvalidTargetingError, /within \(0, 100\]/)
      expect { described_class.normalize(percentage_users: 'lots') }
        .to raise_error(Magick::InvalidTargetingError, /must be a number/)
    end

    it 'validates IP addresses and CIDR ranges' do
      expect(described_class.normalize(ip_addresses: '10.0.0.0/8')).to eq(ip_address: ['10.0.0.0/8'])
      expect { described_class.normalize(excluded_ip_addresses: ['nope']) }
        .to raise_error(Magick::InvalidTargetingError, /invalid IP address/)
    end

    it 'validates date_range bounds' do
      result = described_class.normalize('date_range' => { 'start' => '2026-01-01', 'end' => '2026-02-01' })
      expect(result[:date_range]).to eq(start: '2026-01-01', end: '2026-02-01')

      expect { described_class.normalize(date_range: { start: '2026-01-01' }) }
        .to raise_error(Magick::InvalidTargetingError, /requires both start and end/)
      expect { described_class.normalize(date_range: { start: 'not-a-time', end: '2026-02-01' }) }
        .to raise_error(Magick::InvalidTargetingError, /not a parseable time/)
    end

    it 'normalizes custom attributes and validates operators' do
      result = described_class.normalize(
        'custom_attributes' => { 'plan' => { 'values' => ['pro'], 'operator' => 'not_equals' } }
      )
      expect(result[:custom_attributes]).to eq(plan: { values: ['pro'], operator: :not_equals })

      expect { described_class.normalize(custom_attributes: { plan: { values: ['pro'], operator: 'sounds_like' } }) }
        .to raise_error(Magick::InvalidTargetingError, /unknown operator/)
      expect { described_class.normalize(custom_attributes: { plan: { operator: 'equals' } }) }
        .to raise_error(Magick::InvalidTargetingError, /requires values/)
    end

    it 'normalizes complex conditions and validates their shape' do
      result = described_class.normalize(
        'complex_conditions' => {
          'operator' => 'or',
          'conditions' => [{ 'type' => 'user', 'params' => { 'user_ids' => %w[1 2] } }]
        }
      )
      expect(result[:complex_conditions]).to eq(
        operator: :or,
        conditions: [{ type: :user, params: { user_ids: %w[1 2] } }]
      )

      expect { described_class.normalize(complex_conditions: { operator: 'xor', conditions: [] }) }
        .to raise_error(Magick::InvalidTargetingError, %r{operator must be and/or})
      expect { described_class.normalize(complex_conditions: { conditions: [{ type: 'weather' }] }) }
        .to raise_error(Magick::InvalidTargetingError, /unknown complex condition type/)
    end
  end

  describe '.serialize' do
    it 'returns {} for empty or non-hash targeting' do
      expect(described_class.serialize({})).to eq({})
      expect(described_class.serialize(nil)).to eq({})
    end

    it 'emits string keys, arrays of strings and float percentages' do
      wire = described_class.serialize(user: %w[3], percentage_users: 50)
      expect(wire).to eq('user' => ['3'], 'percentage_users' => 50.0)
    end

    it 'never emits the internal variants entry' do
      wire = described_class.serialize(user: %w[3], variants: [{ name: 'a' }])
      expect(wire.keys).to eq(['user'])
    end

    it 'serializes structured rules with string keys and iso8601 times' do
      wire = described_class.serialize(
        date_range: { start: Time.utc(2026, 1, 1), end: '2026-02-01' },
        custom_attributes: { plan: { values: ['pro'], operator: :equals } }
      )
      expect(wire['date_range']).to eq('start' => '2026-01-01T00:00:00Z', 'end' => '2026-02-01')
      expect(wire['custom_attributes']).to eq('plan' => { 'values' => ['pro'], 'operator' => 'equals' })
    end
  end

  it 'round-trips serialize -> normalize losslessly for list and percentage rules' do
    internal = { user: %w[3 7], excluded_roles: %w[qa], percentage_users: 50.0 }
    expect(described_class.normalize(described_class.serialize(internal))).to eq(internal)
  end
end
