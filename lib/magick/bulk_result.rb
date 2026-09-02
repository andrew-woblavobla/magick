# frozen_string_literal: true

module Magick
  # What a bulk toggle actually did.
  #
  # It iterates as the plain array of features `Magick.bulk_enable` and
  # `Magick.bulk_disable` have always returned, so existing callers keep
  # working. On top of that it names the features the call could not act on,
  # so a partial run is distinguishable from a full one instead of being
  # reported as a blanket success.
  #
  #   result = Magick.bulk_enable(%i[checkout api_version])
  #   result.complete?        # => false
  #   result.changed          # => [#<Magick::Feature checkout>]
  #   result.skipped_reasons  # => { "api_version" => "cannot enable a string feature ..." }
  class BulkResult
    include Enumerable

    # Every feature named in the call, in the order given.
    attr_reader :features

    # The features that were written.
    attr_reader :changed

    # Feature name => why that feature was left untouched.
    attr_reader :skipped_reasons

    def initialize(features, changed, skipped_reasons = {})
      @features = features.freeze
      @changed = changed.freeze
      @skipped_reasons = skipped_reasons.freeze
    end

    def each(&block)
      return features.each unless block

      features.each(&block)
      self
    end

    # The features the call left untouched, in the order given.
    def skipped
      features.select { |feature| skipped_reasons.key?(feature.name) }
    end

    # True when every named feature was written.
    def complete?
      skipped_reasons.empty?
    end

    def to_a
      features.dup
    end
    alias to_ary to_a

    def [](index)
      features[index]
    end

    def size
      features.size
    end
    alias length size

    def empty?
      features.empty?
    end

    def inspect
      "#<#{self.class.name} changed=#{changed.map(&:name)} skipped=#{skipped_reasons}>"
    end
  end
end
