# frozen_string_literal: true

module Magick
  class FeatureVariant
    attr_reader :name, :value, :weight

    def initialize(name, value, weight: 0)
      @name = name.to_s
      @value = value
      @weight = weight.to_f
    end

    def to_h
      { name: name, value: value, weight: weight }
    end
  end
end
