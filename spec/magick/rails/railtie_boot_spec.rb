# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'

# The Railtie is what makes the gem work inside a real Rails process — the
# fork-aware SubscriberMiddleware above all. Until 1.7 nothing required it, so
# it had never been booted: the first boot raised NameError on its middleware
# constant, and every bare `Rails.` inside `module Magick` resolved to the
# gem's own `Magick::Rails` namespace once that was loaded. Booting a real app
# in a child process is the only test that catches either.
RSpec.describe 'Magick::Rails::Railtie boot' do
  let(:script) { File.expand_path('../../fixtures/boot_with_railtie.rb', __dir__) }

  def boot!
    output, status = Open3.capture2e(RbConfig.ruby, script, chdir: File.expand_path('../..', __dir__))
    if output.include?('cannot load such file -- action_controller')
      skip "Rails is not available in this bundle: #{output.lines.last}"
    end
    expect(status).to be_success, "boot failed:\n#{output}"
    JSON.parse(output.lines.grep(/\A\{/).last)
  end

  it 'boots with the Railtie loaded by `require "magick"` and installs the middleware' do
    report = boot!

    expect(report['railtie']).to eq('loaded')
    expect(report['middleware']).to include('Magick::Rails::SubscriberMiddleware')
    expect(report['registry']).to eq('Magick::Adapters::Registry')
    expect(report['request_status']).to eq(404) # went through the whole stack
    expect(report['shutdown']).to be true
  end

  it 'exposes health from the booted registry' do
    report = boot!

    expect(report['health']).to include('subscriber_running' => false, 'refresh_interval' => 30.0)
  end
end

# Inside `module Magick`, a bare `Rails` resolves lexically to `Magick::Rails`
# (the gem's own Rails integration namespace) as soon as that module exists —
# so `Rails.env`, `Rails.logger`, `defined?(Rails)` and `Rails::Generators`
# all have to be spelled `::Rails`. This guards every file, because the boot
# above only exercises the paths a bare boot happens to hit.
RSpec.describe 'Rails constant references inside the gem' do
  let(:bare_rails) { /defined\?\(Rails\)|[^:A-Za-z_.]Rails\.[a-z]|[^:A-Za-z_]Rails::/ }

  it 'spell out ::Rails so Magick::Rails cannot shadow the framework' do
    root = File.expand_path('../../..', __dir__)
    offenders = Dir[File.join(root, '{lib,app}', '**', '*.rb')].flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?('#')
        next if line =~ /^\s*module Rails\s*$/

        "#{file.delete_prefix("#{root}/")}:#{index + 1}: #{line.strip}" if line.match?(bare_rails)
      end
    end

    expect(offenders).to be_empty, "bare Rails references (use ::Rails):\n#{offenders.join("\n")}"
  end
end
