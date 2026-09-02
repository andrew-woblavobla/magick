# frozen_string_literal: true

require 'spec_helper'
require_relative '../../rails_helper'

if MagickRailsApp.available?
  RSpec.describe Magick::AdminUI::Authentication do
    around do |example|
      previous = Magick::AdminUI.config.require_role
      example.run
    ensure
      Magick::AdminUI.config.require_role = previous
    end

    describe '.decision' do
      it 'allows when no hook is configured, so router-gated hosts are unaffected' do
        expect(described_class.decision(nil)).to eq(:allow)
      end

      it 'allows when the hook returns true' do
        expect(described_class.decision(->(_controller) { true })).to eq(:allow)
      end

      it 'denies when the hook returns false' do
        expect(described_class.decision(->(_controller) { false })).to eq(:deny)
      end

      it 'denies when the hook returns nil' do
        expect(described_class.decision(->(_controller) { nil })).to eq(:deny)
      end

      it 'hands the controller to the hook' do
        controller = Object.new
        seen = nil
        described_class.decision(->(c) { seen = c }, controller)
        expect(seen).to be(controller)
      end

      it 'accepts any callable, not just lambdas' do
        callable = Class.new { def call(_controller) = true }.new
        expect(described_class.decision(callable)).to eq(:allow)
      end

      # The defect this replaces: a Symbol is truthy, so it passed the nil
      # guard, failed the callable check, and fell through to no
      # authentication at all.
      it 'denies a Symbol instead of falling through to no authentication' do
        expect(described_class.decision(:admin)).to eq(:deny)
      end

      it 'denies a String instead of falling through to no authentication' do
        expect(described_class.decision('admin')).to eq(:deny)
      end

      it 'denies any other non-callable value' do
        expect(described_class.decision(true)).to eq(:deny)
        expect(described_class.decision(%w[admin manager])).to eq(:deny)
      end

      it 'lets an exception from the hook through rather than hiding a broken hook' do
        boom = ->(_controller) { raise 'current_user is nil' }
        expect { described_class.decision(boom) }.to raise_error(RuntimeError, 'current_user is nil')
      end
    end

    describe 'including the module' do
      # Stands in for a controller: records the filters that get installed and
      # the `head` call the filter makes, without needing a request cycle.
      let(:controller_class) do
        Class.new do
          def self.before_action(*names)
            installed_filters.concat(names)
          end

          def self.installed_filters
            @installed_filters ||= []
          end

          include Magick::AdminUI::Authentication

          attr_reader :headed

          def head(status)
            @headed = status
          end
        end
      end

      it 'installs the authentication filter on the including controller' do
        expect(controller_class.installed_filters).to eq([:authenticate_admin!])
      end

      it 'renders 403 when the configured hook denies' do
        Magick::AdminUI.config.require_role = ->(_controller) { false }
        controller = controller_class.new
        controller.send(:authenticate_admin!)
        expect(controller.headed).to eq(:forbidden)
      end

      it 'renders 403 when the configured hook cannot be called' do
        Magick::AdminUI.config.instance_variable_set(:@require_role, :admin)
        controller = controller_class.new
        controller.send(:authenticate_admin!)
        expect(controller.headed).to eq(:forbidden)
      end

      it 'lets the request through when the hook allows' do
        Magick::AdminUI.config.require_role = ->(_controller) { true }
        controller = controller_class.new
        controller.send(:authenticate_admin!)
        expect(controller.headed).to be_nil
      end

      it 'lets the request through when no hook is configured' do
        Magick::AdminUI.config.require_role = nil
        controller = controller_class.new
        controller.send(:authenticate_admin!)
        expect(controller.headed).to be_nil
      end
    end

    describe 'every Admin UI controller' do
      it 'is gated by the shared filter' do
        controllers = [Magick::AdminUI::FeaturesController, Magick::AdminUI::StatsController]

        expect(controllers).to all(be < described_class)
      end
    end
  end

  # The Configuration class is nested inside `class << self`, so it has no
  # reachable constant path — exercise it through Magick::AdminUI.config.
  RSpec.describe 'Magick::AdminUI.config' do
    around do |example|
      previous = Magick::AdminUI.config.require_role
      example.run
    ensure
      Magick::AdminUI.config.instance_variable_set(:@require_role, previous)
    end

    describe '#require_role=' do
      it 'accepts nil, leaving the panel ungated for router-gated hosts' do
        Magick::AdminUI.config.require_role = nil
        expect(Magick::AdminUI.config.require_role).to be_nil
      end

      it 'accepts a callable' do
        hook = ->(controller) { !controller.nil? }
        Magick::AdminUI.config.require_role = hook
        expect(Magick::AdminUI.config.require_role).to be(hook)
      end

      it 'rejects a Symbol role name loudly instead of ignoring it' do
        expect { Magick::AdminUI.config.require_role = :admin }
          .to raise_error(Magick::ConfigurationError, /must be callable/)
      end

      it 'rejects a String role name loudly instead of ignoring it' do
        expect { Magick::AdminUI.config.require_role = 'admin' }
          .to raise_error(Magick::ConfigurationError, /must be callable/)
      end

      it 'names the offending value so the operator can find it' do
        expect { Magick::AdminUI.config.require_role = :admin }
          .to raise_error(Magick::ConfigurationError, /Symbol \(:admin\)/)
      end

      it 'leaves the previously configured hook in place when it rejects' do
        hook = ->(_controller) { true }
        Magick::AdminUI.config.require_role = hook
        expect { Magick::AdminUI.config.require_role = :admin }.to raise_error(Magick::ConfigurationError)
        expect(Magick::AdminUI.config.require_role).to be(hook)
      end
    end
  end
else
  RSpec.describe 'Magick::AdminUI::Authentication' do
    it 'requires the Rails development dependencies' do
      skip 'Admin UI authentication specs require actionpack/railties'
    end
  end
end
