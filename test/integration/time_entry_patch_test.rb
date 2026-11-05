# frozen_string_literal: true
require_relative 'helper'
require 'minitest/mock'
require_relative '../../lib/myucto/time_entry_patch'

# Exercise the actual callback module on ActiveRecord. This is not a replacement
# for Redmine's controller/REST/bulk integration suite.
ActiveRecord::Schema.define do
  add_column :time_entries, :spent_on, :date
  add_column :time_entries, :hours, :decimal, precision: 8, scale: 2
  add_column :time_entries, :comments, :string
end
class TimeEntry
  reset_column_information
  belongs_to :project
  attr_accessor :issue, :activity
  include Myucto::TimeEntryPatch
end
I18n.backend.store_translations(:en, {
  myucto_invoice_not_editable: 'Invoice %{id} is not editable (%{status})',
  myucto_binding_blocked: 'Invoice %{period} needs verification',
  myucto_change_refused: 'Change refused: %{reason}'
})

class TimeEntryPatchTest < Minitest::Test
  def setup
    [MyuctoSyncEvent, MyuctoTimeLink, MyuctoInvoiceBinding, MyuctoProjectSetting, TimeEntry, Project].each(&:delete_all)
    @project = Project.create!(name: 'Example')
    @setting = MyuctoProjectSetting.create!(project: @project, client_id: 7, enabled: true, allowed_user_ids: [11])
    @api = WorkerApi.new
  end

  def entry
    TimeEntry.create!(project: @project, user_id: 11, author_id: 99, hours: 1.5, spent_on: Date.new(2026, 10, 5), comments: 'Work')
  end

  def synchronize
    Myucto::Worker.new(client: @api).run
  end


  def test_filters_by_time_owner_not_author
    permitted = entry
    excluded = TimeEntry.create!(project: @project, user_id: 99, author_id: 11,
                                hours: 2, spent_on: Date.new(2026, 10, 5), comments: 'Excluded')
    assert_equal [permitted.id], MyuctoSyncEvent.pluck(:time_entry_id)
    assert_equal 11, MyuctoSyncEvent.last.payload_data['user_id']
    refute MyuctoSyncEvent.exists?(time_entry_id: excluded.id)
  end

  def test_empty_allowlist_excludes_new_entries_without_positive_hours_constraint
    @setting.update!(allowed_user_ids: [])
    TimeEntry.create!(project: @project, user_id: 11, hours: 0, spent_on: Date.new(2026, 10, 5))
    assert_empty MyuctoSyncEvent.all
  end

  def test_removed_user_keeps_syncing_existing_entries_but_not_new_ones
    time = entry
    synchronize
    @setting.update!(allowed_user_ids: [])
    Myucto::Client.stub(:new, @api) { time.update!(hours: 3) }
    new_time = entry
    synchronize
    assert_equal 3, @api.reports.values.first['items'].first['hours']
    refute MyuctoSyncEvent.exists?(time_entry_id: new_time.id)
    Myucto::Client.stub(:new, @api) { time.destroy! }
    synchronize
    assert_empty @api.reports.values.first['items']
  end

  def test_adding_user_does_not_import_existing_time_on_normal_update
    @setting.update!(allowed_user_ids: [])
    time = entry
    @setting.update!(allowed_user_ids: [11])
    time.update!(hours: 2)
    assert_empty MyuctoSyncEvent.all
    assert time.myucto_queue_existing!
    assert_equal 1, MyuctoSyncEvent.count
    refute time.myucto_queue_existing!
    assert_equal 1, MyuctoSyncEvent.count
    synchronize
    assert_equal '2026-10-05', @api.reports.values.first['items'].first['work_date']
    assert_equal 2, @api.reports.values.first['items'].first['hours']
    assert_equal time.id, TimeEntry.last.id
  end

  def test_manual_import_refuses_excluded_owner_and_disabled_project
    @setting.update!(allowed_user_ids: [])
    time = entry
    assert_raises(Myucto::Conflict) { time.myucto_queue_existing! }
    @setting.update!(allowed_user_ids: [11], enabled: false)
    assert_raises(Myucto::Conflict) { time.myucto_queue_existing! }
    assert_empty MyuctoSyncEvent.all
  end

  def test_allowlist_is_isolated_by_project
    other = Project.create!(name: 'Other')
    MyuctoProjectSetting.create!(project: other, client_id: 8, enabled: true, allowed_user_ids: [99])
    excluded = TimeEntry.create!(project: other, user_id: 11, hours: 1, spent_on: Date.new(2026, 10, 5))
    permitted = entry
    assert_equal [permitted.id], MyuctoSyncEvent.pluck(:time_entry_id)
    refute MyuctoSyncEvent.exists?(time_entry_id: excluded.id)
  end

  def test_import_keeps_record_timestamps_and_survives_allowlist_change_while_queued
    @setting.update!(allowed_user_ids: [])
    time = entry
    original = time.attributes.dup
    refute_nil original['created_on']
    refute_nil original['updated_on']
    @setting.update!(allowed_user_ids: [11])
    assert time.myucto_queue_existing!
    assert_equal original, time.reload.attributes
    @setting.update!(allowed_user_ids: [])
    synchronize
    assert_equal 'done', MyuctoSyncEvent.last.state
    assert_equal 1, @api.reports.values.first['items'].length
  end

  def test_tracked_entry_continues_after_owner_changes
    time = entry
    synchronize
    Myucto::Client.stub(:new, @api) { time.update!(user_id: 99, hours: 4) }
    synchronize
    assert_equal 4, @api.reports.values.first['items'].first['hours']
    assert_equal 99, MyuctoSyncEvent.last.payload_data['user_id']
  end

  def test_allowed_user_ids_normalize_form_values_and_validate_invalid_input
    @setting.update!(allowed_user_ids: ['', '11', '11', '12'])
    assert_equal [11, 12], @setting.reload.allowed_user_ids
    @setting.allowed_user_ids = ['not-an-id']
    refute @setting.valid?
    refute_empty @setting.errors[:allowed_user_ids]
    @setting.allowed_user_ids = []
    @setting.save!
    refute @setting.transfer_user?(11)
  end

  def test_zero_hours_are_rejected_for_integrated_projects
    time = TimeEntry.new(project: @project, user_id: 11, author_id: 99, hours: 0, spent_on: Date.new(2026, 10, 5), comments: 'Work')
    refute time.save
    refute_empty time.errors[:hours]
    assert_empty MyuctoSyncEvent.all
  end

  def test_create_captures_description_date_and_client_in_same_transaction
    time = entry
    payload = MyuctoSyncEvent.last.payload_data
    assert_equal "Work [TE##{time.id}]", payload['description']
    assert_equal '2026-10-05', payload['spent_on']
    assert_equal 7, payload['client_id']
    assert_equal 1.5, payload['hours']
    TimeEntry.transaction do
      entry
      raise ActiveRecord::Rollback
    end
    assert_equal 1, TimeEntry.count
    assert_equal 1, MyuctoSyncEvent.count
  end

  def test_historical_entry_never_imported_on_update
    @setting.update!(enabled: false)
    time = entry
    @setting.update!(enabled: true)
    time.update!(hours: 2)
    assert_empty MyuctoSyncEvent.all
  end

  def test_issued_invoice_refuses_update_and_delete_with_reason
    time = entry
    synchronize
    @api.invoices.values.first['status'] = 'issued'
    Myucto::Client.stub(:new, @api) do
      refute time.update(hours: 2)
      assert_match(/issued/, time.errors.full_messages.join)
      assert_equal 1.5, time.reload.hours.to_f
      refute time.destroy
      assert TimeEntry.exists?(time.id)
    end
    assert_equal 1, MyuctoSyncEvent.count
  end

  def test_unavailable_api_refuses_update
    time = entry
    synchronize
    @api.define_singleton_method(:invoice) { |_| raise Myucto::Unavailable, 'API offline' }
    Myucto::Client.stub(:new, @api) do
      refute time.update(hours: 2)
      assert_match(/API offline/, time.errors.full_messages.join)
    end
  end

  def test_queued_binding_already_issued_is_guarded_before_link_exists
    time = entry
    @api.invoices[101] = { 'id' => 101, 'status' => 'issued' }
    MyuctoInvoiceBinding.create!(project: @project, period: '2026-10', client_id: 7, invoice_id: 101, state: 'ready')
    Myucto::Client.stub(:new, @api) do
      refute time.update(spent_on: Date.new(2026, 11, 1))
      assert_match(/issued/, time.errors.full_messages.join)
    end
  end

  def test_destroy_enqueues_tombstone_and_rollback_restores_both
    time = entry
    synchronize
    Myucto::Client.stub(:new, @api) do
      TimeEntry.transaction do
        time.destroy!
        raise ActiveRecord::Rollback
      end
      assert TimeEntry.exists?(time.id)
      assert_equal 1, MyuctoSyncEvent.count
      time.reload.destroy!
    end
    assert MyuctoSyncEvent.last.payload_data['deleted']
    synchronize
    assert_empty @api.reports.values.first['items']
  end
end
