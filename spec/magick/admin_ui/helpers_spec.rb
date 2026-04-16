# frozen_string_literal: true

require 'spec_helper'
require 'magick/admin_ui/helpers'

RSpec.describe Magick::AdminUI::Helpers do
  describe '.feature_status_badge' do
    it 'returns an HTML-safe span for :active' do
      result = described_class.feature_status_badge(:active)
      expect(result.to_s).to include('Active')
      expect(result.to_s).to include('badge-success')
    end

    it 'returns an HTML-safe span for :deprecated' do
      result = described_class.feature_status_badge(:deprecated)
      expect(result.to_s).to include('Deprecated')
      expect(result.to_s).to include('badge-warning')
    end

    it 'returns an HTML-safe span for :inactive' do
      result = described_class.feature_status_badge(:inactive)
      expect(result.to_s).to include('Inactive')
      expect(result.to_s).to include('badge-danger')
    end

    it 'falls back to a generic badge for unknown statuses' do
      result = described_class.feature_status_badge(:bogus)
      expect(result.to_s).to include('Unknown')
    end
  end

  describe '.feature_type_label' do
    it { expect(described_class.feature_type_label(:boolean)).to eq('Boolean') }
    it { expect(described_class.feature_type_label(:string)).to eq('String') }
    it { expect(described_class.feature_type_label(:number)).to eq('Number') }
    it { expect(described_class.feature_type_label(:other)).to eq('Other') }
  end
end
