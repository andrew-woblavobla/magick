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

  it 'preserves feature dependencies' do
    Magick.register_feature(:parent)
    Magick.register_feature(:child)
    Magick[:child].instance_variable_set(:@dependencies, ['parent'])

    exported = Magick::ExportImport.export(Magick.features)
    Magick.reset!
    imported = Magick::ExportImport.import(exported, registry)

    deps = imported['child'].instance_variable_get(:@dependencies) || []
    expect(deps).to include('parent')
  end
end
