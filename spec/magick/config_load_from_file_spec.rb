# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Magick::ConfigDSL, '.load_from_file' do
  it 'loads a config file inside the project tree' do
    file = File.join(Dir.pwd, 'spec', 'tmp_magick_config.rb')
    File.write(file, <<~RUBY)
      # frozen_string_literal: true
      # minimal empty config — just ensure the DSL runs
    RUBY

    expect { described_class.load_from_file(file) }.not_to raise_error
  ensure
    File.delete(file) if file && File.exist?(file)
  end

  it 'refuses to load a config file outside the project tree' do
    Dir.mktmpdir do |tmpdir|
      outside = File.join(tmpdir, 'evil.rb')
      File.write(outside, "raise 'should never run'\n")

      expect { described_class.load_from_file(outside) }.to raise_error(SecurityError, /outside the project tree/)
    end
  end

  it 'honors the explicit MAGICK_ALLOW_CONFIG_EVAL opt-out' do
    Dir.mktmpdir do |tmpdir|
      outside = File.join(tmpdir, 'ok.rb')
      File.write(outside, "# allowed by env opt-in\n")

      ENV['MAGICK_ALLOW_CONFIG_EVAL'] = '1'
      expect { described_class.load_from_file(outside) }.not_to raise_error
    ensure
      ENV.delete('MAGICK_ALLOW_CONFIG_EVAL')
    end
  end
end
