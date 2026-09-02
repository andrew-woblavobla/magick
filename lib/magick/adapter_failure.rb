# frozen_string_literal: true

module Magick
  # Makes a failed write to a shared backend visible.
  #
  # The registry writes memory first and never rolls it back, so when the Redis
  # or ActiveRecord write behind it fails, this process keeps serving a value no
  # other process has. That divergence used to be reported with a bare `warn`
  # gated on `Rails.env.development?`, which meant production got no log line,
  # no metric and no event — the split was invisible until someone noticed one
  # container answering differently.
  #
  # Every report now produces, in every environment:
  #   * an error-severity log line (`Rails.logger` when there is one, `$stderr`
  #     otherwise), sanitized through Magick::LogSafe
  #   * a `magick.feature_flag.adapter_write_failed` event on the structured
  #     event channel, so hosts can alert on it
  #
  # Reporting is strictly best effort and never raises: a partial write must not
  # turn into an exception for the caller.
  module AdapterFailure
    # backend   — :redis or :active_record
    # operation — the registry operation that failed (:set, :set_all_data,
    #             :delete, :publish_cache_invalidation, :async_write)
    # error     — the exception that was rescued, when there was one
    # reason    — why the write did not happen, when there was no exception
    #             (e.g. the circuit breaker was open, so the write was dropped)
    def self.report(backend:, operation:, feature_name: nil, error: nil, reason: nil)
      details = describe(backend: backend, operation: operation, feature_name: feature_name,
                         error: error, reason: reason)
      log(details)
      notify(details)
      nil
    rescue StandardError
      # Observability must never break the caller, and never turn a partial
      # write into an exception.
      nil
    end

    def self.describe(backend:, operation:, feature_name:, error:, reason:)
      {
        backend: backend.to_s,
        operation: operation.to_s,
        feature_name: feature_name.nil? ? nil : LogSafe.sanitize(feature_name),
        error_class: error&.class&.name,
        error_message: error.nil? ? nil : LogSafe.sanitize(error.message),
        reason: reason.nil? ? nil : LogSafe.sanitize(reason)
      }
    end
    private_class_method :describe

    def self.message_for(details)
      target = details[:feature_name] ? " for '#{details[:feature_name]}'" : ''
      cause = if details[:error_class]
                "#{details[:error_class]}: #{details[:error_message]}"
              else
                details[:reason] || 'unknown error'
              end

      "Magick: #{details[:backend]} #{details[:operation]} failed#{target}: #{cause}"
    end

    # Error severity, every environment. Falls back to $stderr so the failure is
    # still visible in a plain-Ruby host with no Rails logger.
    def self.log(details)
      message = message_for(details)
      logger = rails_logger
      logger ? logger.error(message) : warn(message)
    rescue StandardError
      nil
    end
    private_class_method :log

    def self.rails_logger
      return nil unless defined?(::Rails) && ::Rails.respond_to?(:logger)

      ::Rails.logger
    rescue StandardError
      nil
    end
    private_class_method :rails_logger

    # The structured event channel only exists once the railtie has loaded it,
    # so a non-Rails host logs and stops there.
    def self.notify(details)
      return unless defined?(::Magick::Rails::Events)

      ::Magick::Rails::Events.adapter_write_failed(
        details[:feature_name],
        **details.slice(:backend, :operation, :error_class, :error_message, :reason)
      )
    rescue StandardError
      nil
    end
    private_class_method :notify
  end
end
