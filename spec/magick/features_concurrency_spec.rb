# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Magick.features thread-safety' do
  it 'does not raise under concurrent register + read' do
    errors = Queue.new
    stop = false

    readers = 8.times.map do
      Thread.new do
        while !stop
          begin
            Magick.features.each_value { |f| f.name }
          rescue RuntimeError, StandardError => e
            errors << e
          end
        end
      end
    end

    writers = 8.times.map do |i|
      Thread.new do
        2_000.times { |j| Magick.register_feature("f#{i}_#{j}".to_sym) }
      rescue StandardError => e
        errors << e
      end
    end

    writers.each(&:join)
    stop = true
    readers.each(&:join)

    drained = []
    drained << errors.pop until errors.empty?
    expect(drained.map { |e| [e.class, e.message] }).to eq([])
  end
end
