# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::ExportImport, 'round-trip' do
  let(:registry) { Magick.default_adapter_registry }

  it 'preserves targeting, exclusions, tags, IP rules and metadata across export/import' do
    skip 'Phase 2.1 — lossless export/import (audit finding P0-5)'

    Magick.register_feature(:demo, display_name: 'Demo', group: 'experiments')
    Magick[:demo].enable_for_user(1)
    Magick[:demo].enable_for_tag('beta')
    Magick[:demo].exclude_user(99)
    Magick[:demo].exclude_ip_addresses('10.0.0.1')

    exported = Magick::ExportImport.export(Magick.features)
    Magick.reset!
    imported = Magick::ExportImport.import(exported, registry)

    f = imported['demo']
    expect(f.display_name).to eq('Demo')
    expect(f.group).to eq('experiments')
    expect(f.targeting[:user]).to include('1')
    expect(f.targeting[:excluded_users]).to include('99')
    expect(f.targeting[:excluded_ip_addresses]).to include('10.0.0.1')
    expect(f.targeting[:tag] || f.targeting[:tags]).to include('beta')
  end
end
