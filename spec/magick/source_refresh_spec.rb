# frozen_string_literal: true

require 'spec_helper'

# End to end: a flag changed behind the gem's back — no process published an
# invalidation — is picked up by evaluation within the refresh interval. This
# is the guarantee that replaces "redeploy to make the toggle take effect" when
# the Pub/Sub leg is broken or bypassed (ADR-0002).
RSpec.describe 'Periodic source refresh' do
  let(:memory) { Magick::Adapters::Memory.new }
  let(:source) { Magick::Adapters::Memory.new } # stands in for the shared backend

  def build_registry(interval)
    Magick::Adapters::Registry.new(memory, active_record_adapter: source, refresh_interval: interval)
  end

  it 'a registered feature follows a value change nobody published, within the interval' do
    Magick.adapter_registry = build_registry(0.05)
    source.set_all_data(:checkout, { 'value' => false })
    Magick.register_feature(:checkout)
    expect(Magick.enabled?(:checkout)).to be false # first evaluation takes the baseline read

    source.set_all_data(:checkout, { 'value' => true }) # raw write into the store: no invalidation
    expect(Magick.enabled?(:checkout)).to be false # not before the interval

    sleep 0.06
    expect(Magick.enabled?(:checkout)).to be true
  end

  it 'targeting follows too — it is cached in the object, not just the value' do
    Magick.adapter_registry = build_registry(0.05)
    source.set_all_data(:checkout, { 'value' => true })
    Magick.register_feature(:checkout)
    expect(Magick.enabled?(:checkout, user_id: '7')).to be true

    source.set_all_data(:checkout, { 'value' => true, 'targeting' => { 'excluded_users' => ['7'] } })
    sleep 0.06

    expect(Magick.enabled?(:checkout, user_id: '7')).to be false
    expect(Magick.enabled?(:checkout, user_id: '8')).to be true
  end

  it 'variants follow as well' do
    Magick.adapter_registry = build_registry(0.05)
    source.set_all_data(:checkout, { 'value' => true })
    Magick.register_feature(:checkout)
    expect(Magick.variant(:checkout, user_id: '7')).to be_nil

    source.set_all_data(:checkout, {
                          'value' => true,
                          'targeting' => { 'variants' => [{ 'name' => 'control', 'weight' => 100 }] }
                        })
    sleep 0.06

    expect(Magick.variant(:checkout, user_id: '7')).to eq('control')
  end

  it 'an unregistered feature follows through the memory cache' do
    Magick.adapter_registry = build_registry(0.05)
    source.set_all_data(:checkout, { 'value' => false })
    expect(Magick.enabled?(:checkout)).to be false

    source.set_all_data(:checkout, { 'value' => true })
    sleep 0.06

    expect(Magick.enabled?(:checkout)).to be true
  end

  it 'does not read the store on every evaluation' do
    counting = Class.new(Magick::Adapters::Memory) do
      attr_reader :loads

      def load_all_features_data
        @loads = (@loads || 0) + 1
        super
      end
    end.new
    Magick.adapter_registry = Magick::Adapters::Registry.new(memory, active_record_adapter: counting,
                                                                     refresh_interval: 30)
    counting.set_all_data(:checkout, { 'value' => true })
    Magick.register_feature(:checkout)

    200.times { Magick.enabled?(:checkout) }

    expect(counting.loads).to eq(1)
  end

  it 'with the refresh off, evaluation never touches the store (the old behavior)' do
    Magick.adapter_registry = build_registry(false)
    source.set_all_data(:checkout, { 'value' => false })
    Magick.register_feature(:checkout)
    source.set_all_data(:checkout, { 'value' => true })
    sleep 0.06

    expect(Magick.enabled?(:checkout)).to be false
  end

  it 'a Feature bound to a bare adapter, without a registry, still evaluates' do
    feature = Magick::Feature.new(:checkout, Magick::Adapters::Memory.new)

    expect { feature.enabled? }.not_to raise_error
  end

  describe 'Magick.refresh!' do
    it 'forces the read now and names what changed' do
      Magick.adapter_registry = build_registry(3600)
      source.set_all_data(:checkout, { 'value' => false })
      Magick.register_feature(:checkout)
      Magick.refresh!
      source.set_all_data(:checkout, { 'value' => true })

      expect(Magick.refresh!).to eq(['checkout'])
      expect(Magick.enabled?(:checkout)).to be true
    end

    it 'returns nil when no shared backend answers' do
      Magick.adapter_registry = Magick::Adapters::Registry.new(memory)

      expect(Magick.refresh!).to be_nil
    end
  end

  describe 'Magick.health' do
    it 'exposes the registry health' do
      Magick.adapter_registry = build_registry(30)

      expect(Magick.health).to include(subscriber_running: false, refresh_interval: 30.0, active_record: true)
    end
  end

  describe 'configuration DSL' do
    it 'refresh_interval sets the interval on the live registry' do
      Magick.configure { refresh_interval 7 }

      expect(Magick.adapter_registry.refresh_interval).to eq(7.0)
    end

    it 'refresh_interval false switches the refresh off' do
      Magick.configure { refresh_interval false }

      expect(Magick.adapter_registry.refresh_interval).to be_nil
    end

    it 'leaves the registry default alone when the file says nothing' do
      Magick.configure { memory_ttl 60 }

      expect(Magick.adapter_registry.refresh_interval).to eq(Magick::Adapters::Registry::DEFAULT_REFRESH_INTERVAL)
    end
  end
end
