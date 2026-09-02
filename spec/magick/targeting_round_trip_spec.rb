# frozen_string_literal: true

require 'spec_helper'

begin
  require 'active_record'
  require 'sqlite3'
  require 'magick/adapters/active_record'
rescue LoadError
  # ActiveRecord/SQLite not available; the adapter-agreement example that
  # needs them is skipped below.
end

# Targeting is written by one process and read by every other one, and every
# adapter round-trips it through JSON. So every example here reloads from
# storage before asserting: an assertion made immediately after the write only
# ever sees the writer's own in-memory hash, which is precisely how variants
# and custom attributes came to be broken everywhere except the process that
# wrote them.
RSpec.describe 'targeting round trip through storage' do
  let(:adapter_registry) { Magick::Adapters::Registry.new(Magick::Adapters::Memory.new) }
  let(:feature) do
    Magick::Feature.new(:checkout_flow, adapter_registry, type: :boolean, default_value: false)
  end

  # Every hash key reachable from `value`, at any depth.
  def nested_key_classes(value)
    case value
    when Hash
      value.flat_map { |k, v| [k.class] + nested_key_classes(v) }
    when Array
      value.flat_map { |v| nested_key_classes(v) }
    else
      []
    end
  end

  describe 'variants' do
    let(:variants) do
      [
        { name: 'control', value: 'old-checkout', weight: 50 },
        { name: 'treatment', value: 'new-checkout', weight: 50 }
      ]
    end

    it 'assigns the same variant before and after a reload' do
      feature.set_variants(variants)
      assigned = feature.get_variant(user_id: '7')
      expect(%w[control treatment]).to include(assigned)

      feature.reload

      expect(feature.get_variant(user_id: '7')).to eq(assigned)
    end

    it 'resolves the variant value after a reload' do
      feature.set_variants(variants)
      values = { 'control' => 'old-checkout', 'treatment' => 'new-checkout' }
      expected = values.fetch(feature.get_variant(user_id: '7'))

      feature.reload

      expect(feature.get_variant_value(user_id: '7')).to eq(expected)
    end

    it 'resolves variants in a process that only ever read them' do
      feature.set_variants(variants)
      assigned = feature.get_variant(user_id: '7')

      reader = Magick::Feature.new(:checkout_flow, adapter_registry, type: :boolean, default_value: false)

      expect(reader.get_variant(user_id: '7')).to eq(assigned)
      expect(reader.get_variant_value(user_id: '7')).not_to be_nil
    end

    it 'keeps the single-variant shortcut working after a reload' do
      feature.set_variants([{ name: 'only', value: 'the-one', weight: 100 }])

      feature.reload

      expect(feature.get_variant).to eq('only')
      expect(feature.get_variant_value).to eq('the-one')
    end
  end

  describe 'custom attributes' do
    # Custom attributes only gate an evaluation that some other rule grants,
    # so each example pairs the attribute with user targeting.
    before do
      feature.enable_for_user(42)
      feature.enable_for_custom_attribute(:plan, %w[pro enterprise], operator: :in)
      feature.set_value(true)
      feature.reload
    end

    it 'matches when the context supplies a symbol key and storage returned a string one' do
      expect(feature.enabled?(user_id: 42, plan: 'pro')).to be true
    end

    it 'matches when the context supplies a string key' do
      expect(feature.enabled?(user_id: 42, 'plan' => 'enterprise')).to be true
    end

    it 'still rejects a non-matching attribute value' do
      expect(feature.enabled?(user_id: 42, plan: 'free')).to be false
    end

    it 'still rejects a context missing the attribute entirely' do
      expect(feature.enabled?(user_id: 42)).to be false
    end
  end

  describe 'complex conditions' do
    before do
      feature.replace_targeting(
        user: %w[42],
        complex_conditions: {
          operator: :or,
          conditions: [
            { type: :role, params: { roles: %w[admin] } },
            { type: :custom_attribute, params: { attribute: :plan, values: %w[pro] } }
          ]
        }
      )
      feature.set_value(true)
      feature.reload
    end

    it 'matches a nested condition after a reload' do
      expect(feature.enabled?(user_id: 42, role: 'admin')).to be true
    end

    it 'rejects a context that satisfies none of the conditions after a reload' do
      expect(feature.enabled?(user_id: 42, role: 'guest')).to be false
    end
  end

  describe 'the loaded targeting hash' do
    it 'is symbol-keyed at every depth' do
      feature.replace_targeting(
        user: %w[42],
        percentage_users: 25,
        date_range: { start: '2024-01-01T00:00:00Z', end: '2034-01-01T00:00:00Z' },
        custom_attributes: { plan: { values: %w[pro], operator: :equals } },
        complex_conditions: {
          operator: :and,
          conditions: [{ type: :group, params: { groups: %w[beta] } }]
        }
      )
      feature.set_variants([{ name: 'control', value: 'a', weight: 100 }])

      feature.reload

      expect(nested_key_classes(feature.targeting).uniq).to eq([Symbol])
    end

    it 'keeps percentages numeric after a reload' do
      feature.replace_targeting(percentage_users: 25)

      feature.reload

      expect(feature.targeting[:percentage_users]).to eq(25.0)
    end

    it 'holds the same shape in the writing process as after a reload' do
      feature.set_variants([{ name: 'control', value: 'a', weight: 100 }])
      feature.enable_for_custom_attribute(:plan, %w[pro])
      in_memory = feature.targeting

      feature.reload

      expect(nested_key_classes(in_memory)).to eq(nested_key_classes(feature.targeting))
      expect(feature.targeting[:variants]).to eq(in_memory[:variants])
    end
  end

  # The three adapters must hand back one shape. They differed before: memory
  # and Redis return what JSON gives them (string keys), while ActiveRecord
  # symbolized recursively — so the first read after boot could yield symbols
  # and every cached read after it strings, for the same flag.
  describe 'adapter key shape agreement' do
    let(:stored) do
      { variants: [{ name: 'control', value: { copy: 'hello' }, weight: 50 }] }
    end
    let(:expected) do
      { 'variants' => [{ 'name' => 'control', 'value' => { 'copy' => 'hello' }, 'weight' => 50 }] }
    end

    # Redis stores strings and nothing else; that is all the adapter's
    # serialization contract depends on. The live-server behaviour is covered
    # by spec/magick/adapters/redis_integration_spec.rb.
    let(:fake_redis_client) do
      Class.new do
        def initialize = @hashes = Hash.new { |h, k| h[k] = {} }
        def hset(key, field, value) = @hashes[key][field.to_s] = value.to_s
        def hget(key, field) = @hashes[key][field.to_s]
        def hgetall(key) = @hashes[key].dup
      end.new
    end

    # #load_all_features_data (the preload! path) routes every value through
    # the same per-adapter deserializer as these two, so pinning them pins it.
    def assert_agrees(adapter)
      adapter.set(:checkout_flow, 'targeting', stored)

      expect(adapter.get(:checkout_flow, 'targeting')).to eq(expected)
      expect(adapter.get_all_data(:checkout_flow)['targeting']).to eq(expected)
    end

    it 'holds for the memory adapter' do
      assert_agrees(Magick::Adapters::Memory.new)
    end

    it 'holds for the Redis adapter' do
      assert_agrees(Magick::Adapters::Redis.new(fake_redis_client))
    end

    it 'holds for the ActiveRecord adapter' do
      skip 'ActiveRecord/SQLite not available' unless defined?(Magick::Adapters::ActiveRecord) && defined?(::SQLite3)

      # A SQLite :memory: database lives and dies with its connection, so
      # reuse whatever connection is already established rather than replacing
      # the pool (and the tables) out from under the other adapter specs.
      begin
        ::ActiveRecord::Base.connection
      rescue ::ActiveRecord::ConnectionNotEstablished
        ::ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      end
      unless ::ActiveRecord::Base.connection.table_exists?('magick_features')
        ::ActiveRecord::Base.connection.create_table :magick_features do |t|
          t.string :feature_name, null: false
          t.text :data
          t.timestamps
        end
      end

      assert_agrees(Magick::Adapters::ActiveRecord.new)
    end
  end
end
