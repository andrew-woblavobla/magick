# frozen_string_literal: true

module Magick
  class Error < StandardError; end
  class FeatureNotFoundError < Error; end
  class InvalidFeatureTypeError < Error; end
  class InvalidFeatureValueError < Error; end
  # Raised by Feature#replace_targeting when a wire targeting payload
  # contains unknown keys or invalid values. Nothing is applied on failure,
  # so API callers can map it straight to a 422.
  class InvalidTargetingError < Error; end
  class AdapterError < Error; end
  # Raised by CircuitBreaker#call when the circuit is open, or when a
  # half-open probe is already in flight. It is an AdapterError because that
  # is what it means to the caller: the backend was never contacted, so the
  # call produced no result. Callers must be able to tell this apart from "the
  # backend answered with a falsey value" — the write path keys its cache
  # invalidation off exactly that distinction.
  class CircuitOpenError < AdapterError; end
  # Raised when a configuration value cannot do the job it was assigned to do
  # — e.g. a `Magick::AdminUI.config.require_role` hook that is not callable.
  # Raised at assignment time so the misconfiguration surfaces at boot rather
  # than being quietly ignored on every request.
  class ConfigurationError < Error; end
end
