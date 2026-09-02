# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::ExportImport, 'round-trip' do
  let(:registry) { Magick.default_adapter_registry }

  it 'preserves display_name and group on round-trip' do
    Magick.register_feature(:demo, display_name: 'Demo Feature', group: 'experiments')
    exported = Magick::ExportImport.export(Magick.features)
    Magick.reset!
    imported = Magick::ExportImport.import(exported, registry)

    f = imported['demo']
    expect(f.display_name).to eq('Demo Feature')
    expect(f.group).to eq('experiments')
  end

  it 'preserves user inclusions and exclusions' do
    Magick.register_feature(:demo)
    Magick[:demo].enable_for_user(1)
    Magick[:demo].exclude_user(99)

    exported = Magick::ExportImport.export(Magick.features)
    Magick.reset!
    imported = Magick::ExportImport.import(exported, registry)

    targeting = imported['demo'].send(:targeting)
    expect(targeting[:user] || targeting['user']).to include('1')
    expect(targeting[:excluded_users] || targeting['excluded_users']).to include('99')
  end

  it 'preserves tag targeting and tag exclusions' do
    Magick.register_feature(:demo)
    Magick[:demo].enable_for_tag('beta')
    Magick[:demo].exclude_tag('blocked')

    exported = Magick::ExportImport.export(Magick.features)
    Magick.reset!
    imported = Magick::ExportImport.import(exported, registry)

    targeting = imported['demo'].send(:targeting)
    expect(targeting[:tag] || targeting['tag']).to include('beta')
    expect(targeting[:excluded_tags] || targeting['excluded_tags']).to include('blocked')
  end

  it 'preserves IP inclusions and exclusions' do
    Magick.register_feature(:demo)
    Magick[:demo].enable_for_ip_addresses('10.0.0.1')
    Magick[:demo].exclude_ip_addresses('10.0.0.99')

    exported = Magick::ExportImport.export(Magick.features)
    Magick.reset!
    imported = Magick::ExportImport.import(exported, registry)

    targeting = imported['demo'].send(:targeting)
    expect(targeting[:ip_address] || targeting['ip_address']).to include('10.0.0.1')
    expect(targeting[:excluded_ip_addresses] || targeting['excluded_ip_addresses']).to include('10.0.0.99')
  end

  describe 'input validation' do
    it 'rejects a payload larger than MAGICK_MAX_IMPORT_FEATURES' do
      big = Array.new(11) { |i| { name: "f#{i}" } }
      ENV['MAGICK_MAX_IMPORT_FEATURES'] = '10'
      expect { Magick::ExportImport.import(big, registry) }.to raise_error(Magick::ExportImport::ImportError, /refused to import 11/)
    ensure
      ENV.delete('MAGICK_MAX_IMPORT_FEATURES')
    end

    it 'rejects non-Hash feature entries' do
      expect { Magick::ExportImport.import([:not_a_hash], registry) }.to raise_error(Magick::ExportImport::ImportError, /must be a Hash/)
    end
  end

  describe 'a feature carrying variants, custom attributes, complex conditions and exclusions' do
    let(:rules) do
      {
        user: %w[1 2 3],
        group: %w[beta],
        excluded_users: %w[3],
        excluded_roles: %w[contractor],
        custom_attributes: { plan: { values: %w[pro enterprise], operator: :in } },
        complex_conditions: {
          operator: :or,
          conditions: [
            { type: :user, params: { user_ids: %w[1 2] } },
            { type: :group, params: { groups: %w[beta] } }
          ]
        }
      }
    end

    let(:variants) do
      [
        { name: 'control', value: '#0066cc', weight: 50.0 },
        { name: 'variant_a', value: '#00cc66', weight: 30.0 },
        { name: 'variant_b', value: '#cc0000', weight: 20.0 }
      ]
    end

    # Contexts chosen so the feature is enabled for some and disabled for
    # others through every rule kind above, in order: user rule + custom
    # attribute + complex user; custom attribute rejects; excluded user;
    # group rule + complex group; complex conditions reject; excluded role;
    # no context at all.
    let(:contexts) do
      [
        { user_id: 1, plan: 'pro' },
        { user_id: 2, plan: 'free' },
        { user_id: 3, plan: 'pro' },
        { user_id: 6, group: 'beta', plan: 'enterprise' },
        { user_id: 6, group: 'gamma', plan: 'pro' },
        { user_id: 7, group: 'beta', plan: 'pro', role: 'contractor' },
        {}
      ]
    end

    def configure(feature)
      feature.replace_targeting(rules)
      feature.set_variants(variants)
      feature
    end

    def assignment(feature)
      (1..40).to_h { |i| [i, [feature.get_variant(user_id: i), feature.get_variant_value(user_id: i)]] }
    end

    it 'exports the variants the feature actually carries' do
      Magick.register_feature(:checkout)
      configure(Magick[:checkout])

      exported = Magick::ExportImport.export(Magick.features).first
      expect(exported[:variants]).to eq(variants)
    end

    it 'survives a full round trip with variant assignment unchanged' do
      Magick.register_feature(:checkout)
      before = configure(Magick[:checkout])
      before_assignment = assignment(before)
      before_targeting = before.targeting
      before_enabled = contexts.map { |context| before.enabled?(context) }

      exported = Magick::ExportImport.export_json(Magick.features)
      Magick.reset!
      after = Magick::ExportImport.import(exported, registry)['checkout']

      # Sanity: the contexts exercise both outcomes, so the comparison below
      # cannot pass by everything being uniformly disabled.
      expect(before_enabled.uniq).to contain_exactly(true, false)
      expect(contexts.map { |context| after.enabled?(context) }).to eq(before_enabled)
      expect(assignment(after)).to eq(before_assignment)
      expect(after.targeting).to eq(before_targeting)
    end

    it 'restores variants from the targeting hash of an older export' do
      # Exports written before the top-level list was populated carried the
      # real variants only inside targeting.
      legacy = [{ 'name' => 'checkout', 'default_value' => false, 'variants' => [],
                  'targeting' => { 'user' => %w[1], 'variants' => variants } }]

      imported = Magick::ExportImport.import(JSON.generate(legacy), registry)['checkout']
      assigned = imported.get_variant(user_id: 1)

      expect(imported.variants_for_export).to eq(variants)
      expect(variants.map { |v| v[:name] }).to include(assigned)
      expect(imported.get_variant_value(user_id: 1)).to eq(variants.find { |v| v[:name] == assigned }[:value])
    end

    it 'does not inherit variants a same-named feature already has in the target store' do
      Magick.register_feature(:checkout)
      configure(Magick[:checkout])

      # Same registry, so the store still holds the variants set above.
      payload = [{ name: 'checkout', default_value: false, targeting: { user: %w[1] } }]
      imported = Magick::ExportImport.import(payload, Magick.default_adapter_registry)['checkout']

      expect(imported.variants_for_export).to be_empty
      expect(imported.get_variant(user_id: 1)).to be_nil
      expect(imported.enabled?(user_id: 1)).to be true
    end
  end

  it 'preserves feature dependencies' do
    Magick.register_feature(:parent)
    Magick.register_feature(:child)
    Magick[:child].add_dependency(:parent)

    exported = Magick::ExportImport.export(Magick.features)
    Magick.reset!
    imported = Magick::ExportImport.import(exported, Magick.default_adapter_registry)

    expect(imported['child'].dependencies).to eq(['parent'])
  end

  it 'persists imported dependencies to the backend' do
    Magick.register_feature(:parent)
    Magick.register_feature(:child)
    Magick[:child].add_dependency(:parent)

    exported = Magick::ExportImport.export(Magick.features)
    Magick.reset!
    target_registry = Magick.default_adapter_registry
    Magick::ExportImport.import(exported, target_registry)

    # A process that only reads the backend sees the imported relationship.
    expect(Magick::Feature.new('child', target_registry).dependencies).to eq(['parent'])
  end

  it 'preserves dependencies through a JSON round trip' do
    Magick.register_feature(:parent)
    Magick.register_feature(:child)
    Magick[:child].add_dependency(:parent)

    json = Magick::ExportImport.export_json(Magick.features)
    Magick.reset!
    imported = Magick::ExportImport.import(json, Magick.default_adapter_registry)

    expect(imported['child'].dependencies).to eq(['parent'])
  end

  it 'applies an explicit empty dependency list' do
    Magick.register_feature(:child)
    Magick[:child].add_dependency(:parent)
    registry_before = Magick.adapter_registry || Magick.default_adapter_registry

    payload = [{ name: 'child', type: 'boolean', default_value: false, dependencies: [] }]
    Magick::ExportImport.import(payload, registry_before)

    expect(Magick::Feature.new('child', registry_before).dependencies).to eq([])
  end

  it 'leaves stored dependencies alone when the payload omits them' do
    Magick.register_feature(:child)
    Magick[:child].add_dependency(:parent)
    registry_before = Magick.adapter_registry || Magick.default_adapter_registry

    Magick::ExportImport.import([{ name: 'child', type: 'boolean', default_value: false }], registry_before)

    expect(Magick::Feature.new('child', registry_before).dependencies).to eq(['parent'])
  end

  it 'rejects a dependency payload that names the feature itself' do
    Magick.register_feature(:child)
    registry_before = Magick.adapter_registry || Magick.default_adapter_registry

    expect { Magick::ExportImport.import([{ name: 'child', type: 'boolean', default_value: false, dependencies: ['child'] }], registry_before) }
      .to raise_error(Magick::ExportImport::ImportError, /invalid dependencies/)
  end
end
