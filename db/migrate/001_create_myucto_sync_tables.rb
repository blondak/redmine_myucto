class CreateMyuctoSyncTables < ActiveRecord::Migration[6.1]
  def change
    create_table :myucto_project_settings do |t|
      t.integer :project_id, null: false
      t.bigint :client_id
      t.boolean :enabled, null: false, default: false
      t.timestamps
    end
    add_index :myucto_project_settings, :project_id, unique: true

    create_table :myucto_invoice_bindings do |t|
      t.integer :project_id, null: false
      t.string :period, limit: 7, null: false
      t.bigint :client_id, null: false
      t.bigint :invoice_id
      t.string :connection_key, limit: 64
      t.string :state, null: false, default: 'pending'
      t.text :error
      t.timestamps
    end
    add_index :myucto_invoice_bindings, [:project_id, :period], unique: true, name: 'myucto_bindings_project_period'
    add_index :myucto_invoice_bindings, :invoice_id, unique: true

    create_table :myucto_time_links do |t|
      t.integer :time_entry_id, null: false
      t.bigint :invoice_binding_id
      t.text :synced_payload
      t.string :state, null: false, default: 'pending'
      t.timestamps
    end
    add_index :myucto_time_links, :time_entry_id, unique: true
    add_index :myucto_time_links, :invoice_binding_id

    create_table :myucto_sync_events do |t|
      t.integer :time_entry_id, null: false
      t.integer :project_id
      t.text :payload, null: false
      t.string :state, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.text :last_error
      t.datetime :available_at
      t.timestamps
    end
    add_index :myucto_sync_events, [:state, :available_at], name: 'myucto_events_worker_queue'
    add_index :myucto_sync_events, :time_entry_id
    add_index :myucto_sync_events, [:project_id, :created_at], name: 'myucto_events_project_history'
  end
end
