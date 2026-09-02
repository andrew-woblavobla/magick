# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Feature dependencies' do
  # One Memory adapter shared by two registries stands in for the shared backend
  # (Redis/ActiveRecord) that separate containers talk to: each "process" gets
  # its own registry, its own Magick.features and its own in-process caches, but
  # they read and write the same stored state.
  let(:backend) { Magick::Adapters::Memory.new }

  def boot_process
    Magick.reset!
    Magick.adapter_registry = Magick::Adapters::Registry.new(backend)
    yield if block_given?
  end

  def stored_dependencies(feature_name)
    Magick.adapter_registry.get(feature_name, 'dependencies')
  end

  # For examples where the unknown-prerequisite warning is expected but is not
  # what the example is asserting on.
  def silence_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end

  before { boot_process }

  describe 'persistence' do
    before do
      Magick.register_feature(:parent)
      Magick.register_feature(:child)
    end

    it 'writes an added dependency to the backend' do
      Magick[:child].add_dependency(:parent)

      expect(stored_dependencies(:child)).to eq(['parent'])
    end

    it 'writes a removed dependency to the backend' do
      Magick[:child].add_dependency(:parent)
      Magick[:child].remove_dependency(:parent)

      expect(stored_dependencies(:child)).to eq([])
    end

    it 'reports the dependency on a freshly constructed instance' do
      Magick[:child].add_dependency(:parent)

      expect(Magick::Feature.new('child', Magick.adapter_registry).dependencies).to eq(['parent'])
    end

    it 'seeds a dependency declared in the DSL' do
      Magick.register_feature(:declared, dependencies: [:parent])

      expect(stored_dependencies(:declared)).to eq(['parent'])
    end

    it 'is a no-op when the dependency is already present' do
      Magick[:child].add_dependency(:parent)
      expect { Magick[:child].add_dependency('parent') }
        .not_to(change { Magick.versioning.get_versions(:child).length })
      expect(Magick[:child].dependencies).to eq(['parent'])
    end

    it 'rejects a self-dependency instead of recursing forever' do
      expect { Magick[:child].add_dependency(:child) }.to raise_error(ArgumentError, /cannot depend on itself/)
    end

    it 'replaces the whole set through #replace_dependencies' do
      Magick[:child].add_dependency(:parent)
      Magick[:child].replace_dependencies(%w[auth billing])

      expect(Magick[:child].dependencies).to eq(%w[auth billing])
      expect(stored_dependencies(:child)).to eq(%w[auth billing])
    end
  end

  describe 'a process that did not declare the relationship' do
    before do
      # Process A: declares nothing, wires the dependency up at runtime.
      Magick.register_feature(:parent)
      Magick.register_feature(:child)
      Magick[:child].add_dependency(:parent)
      Magick[:child].enable
      Magick[:parent].disable
    end

    it 'restores the dependency on restart' do
      boot_process do
        Magick.register_feature(:parent)
        Magick.register_feature(:child)
      end

      expect(Magick[:child].dependencies).to eq(['parent'])
    end

    it 'evaluates the dependent feature as false while the prerequisite is off' do
      boot_process do
        Magick.register_feature(:parent)
        Magick.register_feature(:child)
      end

      expect(Magick[:child].get_value).to be true
      expect(Magick[:child].enabled?).to be false
    end

    it 'evaluates the dependent feature as true once the prerequisite is on' do
      boot_process do
        Magick.register_feature(:parent)
        Magick.register_feature(:child)
      end
      Magick[:parent].enable

      expect(Magick[:child].enabled?).to be true
    end

    it 'sees a removal performed by the other process' do
      Magick[:child].remove_dependency(:parent)

      boot_process do
        Magick.register_feature(:parent)
        Magick.register_feature(:child)
      end

      expect(Magick[:child].dependencies).to eq([])
      expect(Magick[:child].enabled?).to be true
    end

    it 'evaluates a prerequisite that only exists in the backend' do
      # :parent is never registered in this process — it is resolved from
      # stored state instead of being written off as unknown.
      boot_process { Magick.register_feature(:child) }

      expect(Magick.features).not_to have_key('parent')
      expect(Magick[:child].enabled?).to be false

      Magick[:parent].enable
      expect(Magick[:child].enabled?).to be true
    end
  end

  describe 'declaration versus stored state' do
    before do
      Magick.register_feature(:parent)
      Magick.register_feature(:child, dependencies: [:parent])
      Magick[:child].add_dependency(:auth)
    end

    it 'keeps a runtime addition when the declaration is unchanged' do
      boot_process do
        Magick.register_feature(:parent)
        Magick.register_feature(:child, dependencies: [:parent])
      end

      expect(Magick[:child].dependencies).to eq(%w[parent auth])
    end

    it 'keeps stored state for a process that declares nothing' do
      boot_process do
        Magick.register_feature(:parent)
        Magick.register_feature(:child)
      end

      expect(Magick[:child].dependencies).to eq(%w[parent auth])
      expect(stored_dependencies(:child)).to eq(%w[parent auth])
    end

    it 'applies a declaration that changed in code' do
      boot_process do
        Magick.register_feature(:parent)
        Magick.register_feature(:child, dependencies: %i[parent billing])
      end

      expect(Magick[:child].dependencies).to eq(%w[parent billing])
      expect(stored_dependencies(:child)).to eq(%w[parent billing])
    end
  end

  describe 'evaluation' do
    before do
      Magick.register_feature(:parent)
      Magick.register_feature(:child, dependencies: [:parent])
    end

    it 'returns false when any prerequisite is disabled' do
      Magick[:parent].disable
      Magick[:child].enable
      expect(Magick[:child].enabled?).to be false
    end

    it 'returns true when prerequisites are enabled and the feature is enabled' do
      Magick[:parent].enable
      Magick[:child].enable
      expect(Magick[:child].enabled?).to be true
    end

    # State is configuration, not evaluation: a disabled prerequisite must not
    # block the mutator (kept from the 1.4.2 "no destructive cascades" net).
    it 'allows enabling even when a prerequisite is disabled' do
      Magick[:parent].disable

      expect(Magick[:child].enable).to be true
      expect(Magick[:child].enabled?).to be false
    end

    it 'begins evaluating true automatically once the prerequisite is re-enabled' do
      Magick[:parent].disable
      Magick[:child].enable
      expect(Magick[:child].enabled?).to be false

      Magick[:parent].enable
      expect(Magick[:child].enabled?).to be true
    end

    it 'does not cascade — disabling a prerequisite preserves the dependent feature’s configured state' do
      Magick[:parent].enable
      Magick[:child].enable

      Magick[:parent].disable

      # Configured state preserved (value unchanged), but evaluates off.
      expect(Magick[:child].get_value).to be true
      expect(Magick[:child].enabled?).to be false

      # Restoring the prerequisite restores evaluation without re-toggling the dependent.
      Magick[:parent].enable
      expect(Magick[:child].enabled?).to be true
    end

    it 'does not touch unrelated features' do
      Magick.register_feature(:sibling)
      Magick[:sibling].enable
      Magick[:parent].enable
      Magick[:parent].disable
      expect(Magick[:sibling].enabled?).to be true
    end

    it 'evaluates a cycle as unsatisfied instead of overflowing the stack' do
      Magick.register_feature(:a)
      Magick.register_feature(:b)
      Magick[:a].enable
      Magick[:b].enable
      Magick[:a].add_dependency(:b)
      Magick[:b].add_dependency(:a)

      expect { expect(Magick[:a].enabled?).to be false }.to output(/dependency cycle: a -> b -> a/).to_stderr
    end
  end

  describe 'an unknown prerequisite' do
    before do
      Magick.register_feature(:child)
      Magick[:child].add_dependency(:not_deployed_yet)
      Magick[:child].enable
    end

    it 'is treated as satisfied by default' do
      expect(silence_stderr { Magick[:child].enabled? }).to be true
    end

    it 'is reported on stderr rather than failing silently' do
      expect { Magick[:child].enabled? }.to output(/unknown prerequisite 'not_deployed_yet'/).to_stderr
    end

    it 'is reported once per process' do
      expect { Magick[:child].enabled? }.to output(/unknown prerequisite/).to_stderr
      expect { Magick[:child].enabled? }.not_to output.to_stderr
    end

    it 'evaluates the dependent feature as false under the :unsatisfied policy' do
      Magick.unknown_dependency_policy = :unsatisfied

      expect(silence_stderr { Magick[:child].enabled? }).to be false
    end

    it 'stops being unknown once the prerequisite exists' do
      Magick.register_feature(:not_deployed_yet)
      Magick[:not_deployed_yet].disable

      expect(Magick[:child].enabled?).to be false
    end

    it 'rejects an unsupported policy' do
      expect { Magick.unknown_dependency_policy = :maybe }
        .to raise_error(ArgumentError, /must be one of/)
    end

    it 'defaults to :satisfied' do
      expect(Magick.unknown_dependency_policy).to eq(:satisfied)
    end

    it 'is settable through the configuration DSL' do
      Magick.configure do
        unknown_dependency_policy :unsatisfied
      end

      expect(Magick.unknown_dependency_policy).to eq(:unsatisfied)
      expect(silence_stderr { Magick[:child].enabled? }).to be false
    ensure
      # apply! re-enables deprecation warnings for the rest of the suite.
      Magick.warn_on_deprecated = false
    end

    it 'rejects an unsupported policy in the configuration DSL' do
      expect { Magick::Config.new.unknown_dependency_policy(:maybe) }
        .to raise_error(ArgumentError, /must be one of/)
    end
  end

  describe 'versioning' do
    it 'restores and persists dependencies on rollback' do
      Magick.register_feature(:parent)
      Magick.register_feature(:child)
      Magick[:child].add_dependency(:parent)
      version = Magick.versioning.get_versions(:child).last.version
      Magick[:child].remove_dependency(:parent)

      Magick.versioning.rollback(:child, version)

      expect(Magick[:child].dependencies).to eq(['parent'])
      expect(stored_dependencies(:child)).to eq(['parent'])
    end
  end
end
