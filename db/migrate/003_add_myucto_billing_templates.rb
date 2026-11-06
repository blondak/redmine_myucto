# frozen_string_literal: true
class AddMyuctoBillingTemplates < ActiveRecord::Migration[6.1]
  def change
    add_column :myucto_project_settings, :billing_template_id, :bigint
    add_column :myucto_invoice_bindings, :billing_template_id, :bigint
    add_column :myucto_invoice_bindings, :billing_snapshot_json, :text
  end
end
