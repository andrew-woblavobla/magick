# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Magick::LogSafe do
  it 'replaces CR/LF/TAB/ESC and other controls with spaces' do
    input = "evil\nname\rwith\ttabs\e[31mcolour"
    expect(described_class.sanitize(input)).to eq('evil name with tabs [31mcolour')
  end

  it 'truncates to MAX_LEN' do
    result = described_class.sanitize('a' * 1000)
    expect(result.length).to eq(Magick::LogSafe::MAX_LEN)
  end

  it 'respects a custom max override' do
    expect(described_class.sanitize('hello world', max: 5)).to eq('hello')
  end

  it 'accepts non-strings via to_s' do
    expect(described_class.sanitize(42)).to eq('42')
  end
end
