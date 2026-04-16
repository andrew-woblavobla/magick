# frozen_string_literal: true

module Magick
  # Sanitize strings before they go into logs / warnings.
  # Two concerns:
  #   1) Newlines in a user-influenced string (feature name, exception
  #      message) let an attacker forge log entries ("log injection").
  #   2) A long payload can flood a log pipeline.
  # `LogSafe.sanitize` returns a single line at most 256 chars, control
  # characters replaced with spaces.
  module LogSafe
    MAX_LEN = 256
    CONTROL_CHARS = /[\r\n\t\e\u0000-\u001f\u007f]/.freeze

    def self.sanitize(value, max: MAX_LEN)
      str = value.to_s.dup
      str.gsub!(CONTROL_CHARS, ' ')
      str = str[0, max] if str.length > max
      str
    end
  end
end
