# frozen_string_literal: true

module Magick
  class Error < StandardError; end
  class FeatureNotFoundError < Error; end
  class InvalidFeatureTypeError < Error; end
  class InvalidFeatureValueError < Error; end
  class AdapterError < Error; end
end
