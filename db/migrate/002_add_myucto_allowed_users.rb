# frozen_string_literal: true
class AddMyuctoAllowedUsers < ActiveRecord::Migration[6.1]
  def change
    # NULL means nobody: existing queued/linked entries continue independently.
    add_column :myucto_project_settings, :allowed_user_ids_json, :text
  end
end
