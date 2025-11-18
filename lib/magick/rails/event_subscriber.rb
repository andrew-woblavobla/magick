# frozen_string_literal: true

module Magick
  module Rails
    # Example event subscriber for Rails 8.1+ structured events
    # Users can create custom subscribers to handle Magick events
    class EventSubscriber
      def initialize
        @subscribed = false
      end

      # Subscribe to all Magick events
      def subscribe_to_all
        return unless Events.rails81?

        Events::EVENTS.each_value do |event_name|
          subscribe_to(event_name)
        end
        @subscribed = true
      end

      # Subscribe to a specific event
      def subscribe_to(event_name, &block)
        return unless Events.rails81?

        full_event_name = Events::EVENTS[event_name] || event_name.to_s
        Rails.event.subscribe(full_event_name, self)
      end

      # Implement the emit method required by Rails 8.1 event system
      def emit(event)
        # event is a hash with :name, :payload, :source_location, :tags, :context
        handle_event(event)
      end

      private

      def handle_event(event)
        # Default handler - users can override
        Rails.logger&.info "Magick Event: #{event[:name]} - #{event[:payload].inspect}"
      end
    end

    # Default log subscriber for Magick events
    class LogSubscriber
      def emit(event)
        payload = event[:payload].map { |key, value| "#{key}=#{value}" }.join(" ")
        source_location = event[:source_location]
        log = "[#{event[:name]}] #{payload}"
        log += " at #{source_location[:filepath]}:#{source_location[:lineno]}" if source_location
        Rails.logger&.info(log)
      end
    end
  end
end
