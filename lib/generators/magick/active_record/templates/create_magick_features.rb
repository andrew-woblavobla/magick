# frozen_string_literal: true

class CreateMagickFeatures < ActiveRecord::Migration[<%= ActiveRecord::Migration.current_version %>]
  def change
<% if @use_uuid -%>
    enable_extension 'pgcrypto' if adapter_name == 'PostgreSQL'
    create_table :magick_features, id: :uuid do |t|
<% else -%>
    create_table :magick_features do |t|
<% end -%>
      t.string :feature_name, null: false, index: { unique: true }
<% if @is_postgresql -%>
      t.jsonb :data
<% else -%>
      t.text :data
<% end -%>
      t.timestamps
    end
  end
end
