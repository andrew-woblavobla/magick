# frozen_string_literal: true

module Magick
  module Generators
    class ActiveRecordGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Creates a migration for Magick feature flags table (ActiveRecord adapter)'
      class_option :uuid, type: :boolean, default: false, desc: 'Use UUID as primary key'

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_migration
        unless defined?(::ActiveRecord::Base)
          say 'ActiveRecord is not available. This generator requires ActiveRecord.', :red
          exit 1
        end

        migration_number = self.class.next_migration_number('db/migrate')
        @use_uuid = options[:uuid]
        @is_postgresql = postgresql?
        template 'create_magick_features.rb', "db/migrate/#{migration_number}_create_magick_features.rb"
      end

      private

      def postgresql?
        return false unless defined?(::ActiveRecord::Base)

        begin
          adapter = ActiveRecord::Base.connection.adapter_name.downcase
          adapter == 'postgresql' || adapter == 'postgis'
        rescue StandardError
          # If we can't connect, check database.yml or default to false
          false
        end
      end
    end
  end
end
