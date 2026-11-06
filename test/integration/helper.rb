# frozen_string_literal: true

# These tests use the plugin's real migration and models with ActiveRecord and
# SQLite. Project/TimeEntry stand in only for Redmine's owning tables; this does
# not boot Redmine or exercise its controllers, callbacks or permissions.
require 'minitest/autorun'
require 'active_record'
require 'sqlite3'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Base.belongs_to_required_by_default = true
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  create_table(:projects) { |table| table.string :name }
  create_table(:time_entries) do |table|
    table.integer :project_id
    table.integer :user_id
    table.integer :author_id
    table.datetime :created_on
    table.datetime :updated_on
  end
end

class Project < ActiveRecord::Base; end
class TimeEntry < ActiveRecord::Base; end

require_relative '../../db/migrate/001_create_myucto_sync_tables'
CreateMyuctoSyncTables.new.migrate(:up)
require_relative '../../db/migrate/002_add_myucto_allowed_users'
AddMyuctoAllowedUsers.new.migrate(:up)
require_relative '../../db/migrate/003_add_myucto_billing_templates'
AddMyuctoBillingTemplates.new.migrate(:up)
%w[project_setting invoice_binding time_link sync_event].each do |name|
  require_relative "../../app/models/myucto_#{name}"
end
require_relative '../../lib/myucto'

module Myucto
  def self.configuration
    { 'base_url' => 'https://billing.example.test', 'supplier_id' => '7' }
  end
end

class WorkerApi
  attr_accessor :create_failure, :save_failure
  attr_reader :invoices, :reports, :creates, :writes

  def initialize
    @invoices = {}
    @reports = {}
    @creates = []
    @writes = []
  end

  def verify_connection!
    true
  end

  def create_invoice(**attributes)
    creates << attributes
    id = creates.size + 100
    invoices[id] = { 'id' => id, 'status' => 'draft', 'items' => [], 'currency' => attributes.fetch(:currency, 'CZK') }
    raise create_failure if create_failure
    copy(invoices[id])
  end

  def invoice(id)
    copy(invoices.fetch(id))
  end

  def work_report(id)
    copy(reports[id])
  end

  def save_work_report(id, report)
    save_failure&.call(id, report)
    writes << [id, copy(report)]
    reports[id] = (reports[id] || {}).merge(copy(report))
    reports[id]['items'].each_with_index do |row, index|
      row['id'] = index + 500
      row['rate'] = row['rate'].to_f
      row['hours'] = row['hours'].to_f
      row['order_index'] ||= index
    end
    copy(reports[id])
  end

  def copy(value)
    Marshal.load(Marshal.dump(value))
  end
end
