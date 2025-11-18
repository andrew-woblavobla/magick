# frozen_string_literal: true

module Magick
  module Targeting
    class Base
      def matches?(context)
        raise NotImplementedError, "#{self.class} must implement #matches?"
      end
    end
  end
end
