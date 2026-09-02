# frozen_string_literal: true

require 'spec_helper'
require 'request_store'
require 'magick/request_store_integration'

RSpec.describe Magick::RequestStoreIntegration do
  # The railtie installs this once at boot; do the same here so the specs
  # exercise the real `Magick.enabled?` and not a stand-in.
  before(:all) { described_class.install! }

  # Belt and braces: the middleware closes the request itself, but a spec that
  # hides the constant must not leave the store open for the next one.
  after do
    next unless defined?(RequestStore)

    RequestStore.end!
    RequestStore.clear!
  end

  # Runs the block the way Rack does: inside RequestStore's own middleware, so
  # the store is opened before it and cleared after it. Two calls to this are
  # two requests.
  def in_request
    result = nil
    app = lambda do |_env|
      result = yield
      [200, {}, []]
    end
    body = RequestStore::Middleware.new(app).call({}).last
    body.close
    result
  end

  def register(name, default_value: true)
    Magick.register_feature(name, type: :boolean, default_value: default_value).tap do |feature|
      allow(feature).to receive(:enabled?).and_call_original
    end
  end

  describe '.install!' do
    it 'prepends onto the singleton class, ahead of a directly defined enabled?' do
      target = Module.new do
        def self.enabled?(_feature_name, _context = {})
          :uncached
        end
      end

      expect(described_class.install!(target)).to be true
      expect(target.singleton_class.ancestors.first).to eq(described_class)
    end

    it 'is idempotent' do
      target = Module.new do
        def self.enabled?(_feature_name, _context = {})
          false
        end
      end

      described_class.install!(target)
      expect(described_class.install!(target)).to be false
      expect(target.singleton_class.ancestors.count(described_class)).to eq(1)
    end

    it 'is installed on Magick' do
      expect(described_class).to be_installed
    end
  end

  describe 'within a single request' do
    it 'evaluates the feature once across repeated checks' do
      feature = register('checkout')

      results = in_request { Array.new(3) { Magick.enabled?(:checkout, user_id: 7) } }

      expect(results).to eq([true, true, true])
      expect(feature).to have_received(:enabled?).once
    end

    it 'memoises a false answer too' do
      feature = register('checkout', default_value: false)

      results = in_request { Array.new(3) { Magick.enabled?(:checkout) } }

      expect(results).to eq([false, false, false])
      expect(feature).to have_received(:enabled?).once
    end

    it 'treats a symbol and a string feature name as the same check' do
      feature = register('checkout')

      in_request do
        Magick.enabled?(:checkout, user_id: 1)
        Magick.enabled?('checkout', user_id: 1)
      end

      expect(feature).to have_received(:enabled?).once
    end

    it 'evaluates separately for different contexts' do
      feature = register('checkout')

      in_request do
        Magick.enabled?(:checkout, user_id: 1)
        Magick.enabled?(:checkout, user_id: 2)
      end

      expect(feature).to have_received(:enabled?).twice
    end

    it 'covers Magick.disabled?, which routes through enabled?' do
      feature = register('checkout')

      results = in_request { [Magick.enabled?(:checkout), Magick.disabled?(:checkout)] }

      expect(results).to eq([true, false])
      expect(feature).to have_received(:enabled?).once
    end

    it 'gives a percentage-of-requests rollout a single answer for the whole request' do
      register('flaky').enable_percentage_of_requests(50)

      answers = in_request { Array.new(100) { Magick.enabled?(:flaky) } }

      expect(answers.uniq.size).to eq(1)
    end
  end

  describe 'across requests' do
    it 'starts each request with an empty cache' do
      feature = register('checkout')

      2.times { in_request { Array.new(3) { Magick.enabled?(:checkout) } } }

      expect(feature).to have_received(:enabled?).twice
    end

    it 're-rolls a percentage-of-requests rollout on the next request' do
      register('flaky').enable_percentage_of_requests(50)

      answers = Array.new(100) { in_request { Magick.enabled?(:flaky) } }

      expect(answers.uniq).to contain_exactly(true, false)
    end

    it 'leaves nothing behind in the store' do
      register('checkout')

      in_request { Magick.enabled?(:checkout) }

      expect(RequestStore.store).not_to have_key(described_class::STORE_KEY)
    end
  end

  describe '.clear!' do
    it 'drops answers memoised earlier in the same request' do
      feature = register('checkout')

      in_request do
        Magick.enabled?(:checkout)
        described_class.clear!
        Magick.enabled?(:checkout)
      end

      expect(feature).to have_received(:enabled?).twice
    end
  end

  describe 'outside a request' do
    it 'evaluates every call rather than memoising with nothing to clear it' do
      feature = register('checkout')

      results = Array.new(3) { Magick.enabled?(:checkout) }

      expect(results).to eq([true, true, true])
      expect(feature).to have_received(:enabled?).exactly(3).times
      expect(RequestStore.store).not_to have_key(described_class::STORE_KEY)
    end
  end

  describe 'when the request_store gem is absent' do
    before { hide_const('RequestStore') }

    it 'evaluates every call' do
      feature = register('checkout', default_value: false)

      results = Array.new(3) { Magick.enabled?(:checkout) }

      expect(results).to eq([false, false, false])
      expect(feature).to have_received(:enabled?).exactly(3).times
    end

    it 'leaves a percentage-of-requests rollout re-rolling per check' do
      register('flaky').enable_percentage_of_requests(50)

      answers = Array.new(100) { Magick.enabled?(:flaky) }

      expect(answers.uniq).to contain_exactly(true, false)
    end

    it 'is safe to clear!' do
      expect { described_class.clear! }.not_to raise_error
    end
  end
end
