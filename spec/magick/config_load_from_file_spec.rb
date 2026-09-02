# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Magick::ConfigDSL, '.load_from_file' do
  around do |example|
    previous = described_class.instance_variable_get(:@project_root)
    example.run
    described_class.project_root = previous
  end

  # File.realpath resolves symlinks, and on macOS Dir.mktmpdir hands back a
  # path under /var, which is a symlink to /private/var. Compare like for like.
  def real(path)
    File.realpath(path)
  end

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

  it 'refuses a sibling directory whose name merely starts with the project root' do
    Dir.mktmpdir do |tmpdir|
      root = File.join(tmpdir, 'app')
      sibling = File.join(tmpdir, 'app-evil')
      Dir.mkdir(root)
      Dir.mkdir(sibling)
      evil = File.join(sibling, 'features.rb')
      File.write(evil, "raise 'should never run'\n")
      described_class.project_root = root

      # Run from inside the root too: a bare string prefix would accept
      # `.../app-evil/features.rb` as living under `.../app`.
      Dir.chdir(root) do
        expect { described_class.load_from_file(evil) }
          .to raise_error(SecurityError, /outside the project tree/)
      end
    end
  end

  it 'accepts a nested file under the project root' do
    Dir.mktmpdir do |tmpdir|
      root = File.join(tmpdir, 'app')
      Dir.mkdir(root)
      Dir.mkdir(File.join(root, 'config'))
      inside = File.join(root, 'config', 'features.rb')
      File.write(inside, "# nested but contained\n")
      described_class.project_root = root

      expect { described_class.load_from_file(inside) }.not_to raise_error
    end
  end

  it 'still refuses outside files when the process runs from the filesystem root' do
    Dir.mktmpdir do |tmpdir|
      outside = File.join(tmpdir, 'evil.rb')
      File.write(outside, "raise 'should never run'\n")

      Dir.chdir('/') do
        expect { described_class.load_from_file(outside) }
          .to raise_error(SecurityError, /outside the project tree/)
      end
    end
  end

  it 'still loads project files when the process runs from the filesystem root' do
    file = File.join(described_class.project_root, 'spec', 'tmp_magick_config_cwd.rb')
    File.write(file, "# loaded from a different cwd\n")

    Dir.chdir('/') do
      expect { described_class.load_from_file(file) }.not_to raise_error
    end
  ensure
    File.delete(file) if file && File.exist?(file)
  end

  it 'refuses everything when the detected project root is the filesystem root' do
    Dir.mktmpdir do |tmpdir|
      candidate = File.join(tmpdir, 'features.rb')
      File.write(candidate, "raise 'should never run'\n")
      described_class.project_root = '/'

      expect { described_class.load_from_file(candidate) }
        .to raise_error(SecurityError, /outside the project tree/)
    end
  end

  it 'refuses everything when no project root can be determined' do
    Dir.mktmpdir do |tmpdir|
      candidate = File.join(tmpdir, 'features.rb')
      File.write(candidate, "raise 'should never run'\n")
      described_class.project_root = nil
      allow(described_class).to receive(:detect_project_root).and_return(nil)

      expect { described_class.load_from_file(candidate) }
        .to raise_error(SecurityError, /project root could not be determined/)
    end
  end

  describe '.project_root' do
    it 'does not follow the process working directory' do
      from_repo = described_class.project_root
      from_slash = Dir.chdir('/') { described_class.project_root }

      expect(from_slash).to eq(from_repo)
      expect(from_slash).not_to eq('/')
    end

    it 'prefers an explicitly configured root and resolves symlinks in it' do
      Dir.mktmpdir do |tmpdir|
        root = File.join(tmpdir, 'app')
        Dir.mkdir(root)
        described_class.project_root = root

        expect(described_class.project_root).to eq(real(root))
      end
    end
  end
end
