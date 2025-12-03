# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::Documentation do
  # TODO: Implement feature flag documentation generation
  # Requirements:
  # - Auto-generate docs from feature definitions
  # - Should include feature name, type, default value, description, status
  # - Should include targeting rules and dependencies

  # Documentation is implemented, no skip needed

  describe '.generate' do
    it 'generates documentation from registered features' do
      Magick.register_feature(:test_feature,
        type: :boolean,
        default_value: false,
        description: 'Test feature description',
        status: :active
      )

      docs = described_class.generate
      expect(docs).to include('test_feature')
      expect(docs).to include('Test feature description')
    end

    it 'includes feature type in documentation' do
      Magick.register_feature(:string_feature, type: :string, default_value: 'v1')
      Magick.register_feature(:number_feature, type: :number, default_value: 10)

      docs = described_class.generate
      expect(docs).to include('string')
      expect(docs).to include('number')
    end

    it 'includes default values in documentation' do
      Magick.register_feature(:test_feature, type: :boolean, default_value: true)
      docs = described_class.generate
      expect(docs).to include('true')
    end

    it 'includes feature status in documentation' do
      Magick.register_feature(:deprecated_feature, type: :boolean, default_value: false, status: :deprecated)
      docs = described_class.generate
      expect(docs).to include('deprecated')
    end

    it 'includes targeting rules in documentation' do
      Magick.register_feature(:test_feature, type: :boolean, default_value: false)
      feature = Magick[:test_feature]
      feature.enable_for_user(123)
      feature.enable_for_group('beta_testers')

      docs = described_class.generate(format: :markdown)
      expect(docs).to include('**user_id:** 123')
      expect(docs).to include('beta_testers')
    end

    it 'includes dependencies in documentation' do
      Magick.register_feature(:base_feature, type: :boolean, default_value: false)
      Magick.register_feature(:dependent_feature, type: :boolean, default_value: false, dependencies: [:base_feature])

      docs = described_class.generate
      expect(docs).to include('dependent_feature')
      expect(docs).to include('base_feature')
    end
  end

  describe '.generate_markdown' do
    it 'generates markdown formatted documentation' do
      Magick.register_feature(:test_feature, type: :boolean, default_value: false, description: 'Test')
      docs = described_class.generate_markdown
      expect(docs).to include('#')
      expect(docs).to include('##')
    end
  end

  describe '.generate_html' do
    it 'generates HTML formatted documentation' do
      Magick.register_feature(:test_feature, type: :boolean, default_value: false, description: 'Test')
      docs = described_class.generate_html
      expect(docs).to include('<html>')
      expect(docs).to include('<table>')
    end
  end

  describe '.generate_json' do
    it 'generates JSON formatted documentation' do
      Magick.register_feature(:test_feature, type: :boolean, default_value: false, description: 'Test')
      docs = described_class.generate_json
      parsed = JSON.parse(docs)
      expect(parsed).to be_a(Array)
      expect(parsed.first['name']).to eq('test_feature')
    end
  end
end
