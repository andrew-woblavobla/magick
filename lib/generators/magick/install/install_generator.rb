# frozen_string_literal: true

module Magick
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      desc 'Creates a Magick configuration file at config/initializers/magick.rb'

      def create_initializer
        template 'magick.rb', 'config/initializers/magick.rb'
      end

      def show_readme
        readme 'README' if behavior == :invoke
      end
    end
  end
end
