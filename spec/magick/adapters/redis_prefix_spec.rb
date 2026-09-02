# frozen_string_literal: true

require 'spec_helper'

# The Redis adapter's prefix-scoped bulk loads, driven by a stand-in client so
# they are covered by a plain `bundle exec rspec`. The redis gem is not a
# dependency, and requiring it here would flip Magick's `defined?(Redis)`
# auto-detection for the rest of the suite; the behaviour against a real server
# is asserted in redis_integration_spec.rb.
RSpec.describe Magick::Adapters::Redis, 'prefix-scoped bulk loads' do
  # Just enough of the Redis command surface for hash reads and SCAN.
  let(:client) do
    Class.new do
      attr_reader :hashes

      def initialize
        @hashes = {}
      end

      def hset(key, field, value)
        (@hashes[key] ||= {})[field] = value
      end

      def hgetall(key)
        @hashes[key] || {}
      end

      def scan(_cursor, match:, count: nil)
        pattern = Regexp.new("\\A#{glob_to_regexp(match)}\\z")
        ['0', @hashes.keys.grep(pattern)]
      end

      def pipelined
        collected = []
        yield Collector.new(self, collected)
        collected
      end

      # Stands in for the pipeline object commands are queued on.
      class Collector
        def initialize(client, results)
          @client = client
          @results = results
        end

        def hgetall(key)
          @results << @client.hgetall(key)
        end
      end

      private

      def glob_to_regexp(glob)
        glob.gsub(/\\.|[*?]|[^\\*?]+/) do |token|
          case token
          when '*' then '.*'
          when '?' then '.'
          else Regexp.escape(token.start_with?('\\') ? token[1] : token)
          end
        end
      end
    end.new
  end

  let(:adapter) { described_class.new(client) }
  let(:versions) { Magick::Versioning::STORE_PREFIX }
  let(:audit) { Magick::AuditLog::STORE_PREFIX }

  before do
    adapter.set('billing', 'value', true)
    adapter.set("#{versions}billing", 'version_1', { 'version' => 1 })
    adapter.set("#{versions}billing", 'version_2', { 'version' => 2 })
    adapter.set("#{audit}billing", 'entry_1', { 'action' => 'enable' })
  end

  it 'loads only the features under the prefix' do
    loaded = adapter.load_features_data_with_prefix(versions)

    expect(loaded.keys).to eq(["#{versions}billing"])
    expect(loaded["#{versions}billing"].keys).to match_array(%w[version_1 version_2])
  end

  # The hot window lives in Redis too, so a preload that did not filter here
  # would pull every cached snapshot into the worker alongside the features.
  it 'loads everything except the features under the reserved prefixes' do
    expect(adapter.load_features_data_without_prefixes([versions, audit]).keys).to eq(['billing'])
  end

  it 'never fetches the hashes it excludes' do
    fetched = []
    allow(client).to receive(:hgetall).and_wrap_original do |original, key|
      fetched << key
      original.call(key)
    end

    adapter.load_features_data_without_prefixes([versions, audit])

    expect(fetched).to eq(['magick:features:billing'])
  end

  it 'treats glob metacharacters in the prefix as literals' do
    adapter.set('a*b', 'value', true)
    adapter.set('axb', 'value', true)

    expect(adapter.load_features_data_with_prefix('a*').keys).to eq(['a*b'])
  end
end
