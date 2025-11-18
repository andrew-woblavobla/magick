# frozen_string_literal: true

require 'ipaddr'

module Magick
  module Targeting
    class IpAddress < Base
      def initialize(ip_addresses)
        @ip_addresses = Array(ip_addresses).map { |ip| IPAddr.new(ip) }
      end

      def matches?(context)
        return false unless context[:ip_address]

        client_ip = IPAddr.new(context[:ip_address])
        @ip_addresses.any? { |ip| ip.include?(client_ip) }
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
