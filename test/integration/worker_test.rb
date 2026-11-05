# frozen_string_literal: true
require_relative 'helper'

class WorkerIntegrationTest < Minitest::Test
  def setup
    [MyuctoSyncEvent, MyuctoTimeLink, MyuctoInvoiceBinding, MyuctoProjectSetting, TimeEntry, Project].each(&:delete_all)
    @project = Project.create!(name: 'Example')
    @setting = MyuctoProjectSetting.create!(project: @project, client_id: 7, enabled: true)
    @api = WorkerApi.new
    @worker = Myucto::Worker.new(client: @api)
  end

  def enqueue(time_entry_id = 1, **changes)
    data = { 'project_id' => @project.id, 'project_name' => @project.name, 'client_id' => 7,
             'spent_on' => '2026-10-05', 'hours' => 2, 'description' => 'Example task' }
    data.merge!(changes.transform_keys(&:to_s))
    MyuctoSyncEvent.create!(time_entry_id: time_entry_id, project_id: data['project_id'], payload: JSON.generate(data))
  end

  def binding(period = '2026-10', project = @project)
    MyuctoInvoiceBinding.find_by!(project_id: project.id, period: period)
  end

  def link(time_entry_id = 1)
    MyuctoTimeLink.find_by!(time_entry_id: time_entry_id)
  end

  def ready_again(event)
    event.reload.update!(state: 'pending', available_at: nil)
  end


  def test_move_preserves_remote_rate_across_failed_target_write
    enqueue
    @worker.run
    source_id = binding.invoice_id
    @api.reports[source_id]['items'][0]['rate'] = 1750
    event = enqueue(1, spent_on: '2026-11-01')
    @api.save_failure = ->(id, _) { raise Myucto::Unavailable, 'offline' if id != source_id }
    @worker.run
    assert_equal 'removed', link.state
    assert_equal 1750, link.synced_payload_data['rate']
    @api.save_failure = nil
    ready_again(event)
    @worker.run
    assert_equal 'done', event.reload.state, event.last_error
    assert_equal 1750, @api.reports[binding('2026-11').invoice_id]['items'][0]['rate']
  end

  def test_disable_after_enqueue_still_finishes_authorized_new_entry
    event = enqueue(1, integration_enabled: true)
    @setting.update!(enabled: false)
    @worker.run
    assert_equal 'done', event.reload.state
  end


  def test_blocked_entries_do_not_starve_unrelated_work_beyond_batch_limit
    blocked = enqueue(1)
    blocked.update!(state: 'conflict')
    5.times { enqueue(1) }
    other = enqueue(2)
    assert_equal 1, @worker.run(limit: 1)
    assert_equal 'done', other.reload.state
    assert_equal 'conflict', blocked.reload.state
  end

  def test_first_entry_creates_one_empty_draft_and_same_month_reuses_it
    first = enqueue
    second = enqueue(2, description: 'Second task')
    assert_equal 2, @worker.run
    assert_equal ['done', 'done'], [first.reload.state, second.reload.state]
    assert_equal 1, @api.creates.size
    assert_equal 'ready', binding.state
    assert_equal binding.id, link.invoice_binding_id
    assert_equal binding.id, link(2).invoice_binding_id
    assert_equal [], @api.invoices.fetch(binding.invoice_id).fetch('items')
    assert_equal ['Example task [TE#1]', 'Second task [TE#2]'], @api.reports.fetch(binding.invoice_id)['items'].map { |row| row['description'] }
  end

  def test_edit_and_delete_preserve_manual_rows_and_remote_rate
    enqueue
    @worker.run
    report = @api.reports.fetch(binding.invoice_id)
    report['items'][0]['rate'] = 1800
    manual = { 'description' => 'Manual task', 'hours' => 3, 'rate' => 500, 'order_index' => 1, 'work_date' => '2026-10-03' }
    report['items'] << manual
    edit = enqueue(1, hours: 4, description: 'Updated task')
    @worker.run
    assert_equal 'done', edit.reload.state
    report = @api.reports.fetch(binding.invoice_id)
    assert_equal 1800, report['items'][0]['rate']
    assert_equal 4, report['items'][0]['hours']
    assert_equal 'Updated task [TE#1]', report['items'][0]['description']
    assert_equal 'Manual task', report['items'][1]['description']
    deletion = enqueue(1, deleted: true)
    @worker.run
    assert_equal 'done', deletion.reload.state
    assert_equal 'deleted', link.state
    assert_nil link.invoice_binding_id
    assert_equal ['Manual task'], @api.reports.fetch(binding.invoice_id)['items'].map { |row| row['description'] }
  end

  def test_deleting_last_entry_retains_empty_work_report_and_invoice
    enqueue
    @worker.run
    invoice_id = binding.invoice_id
    enqueue(1, deleted: true)
    @worker.run
    assert_equal [], @api.reports.fetch(invoice_id)['items']
    assert_equal 'draft', @api.invoices.fetch(invoice_id)['status']
    assert_equal 1, @api.creates.size
  end

  def test_move_retries_after_source_removal_and_uses_one_target_draft
    enqueue
    @worker.run
    source_id = binding.invoice_id
    move = enqueue(1, spent_on: '2026-11-01', hours: 5)
    @api.save_failure = lambda do |id, _report|
      raise Myucto::Unavailable, 'Temporary outage' if id != source_id
    end
    @worker.run
    target_id = binding('2026-11').invoice_id
    assert_equal 'pending', move.reload.state
    assert_equal 1, move.attempts
    assert_operator move.available_at, :>, Time.current
    assert_equal [], @api.reports.fetch(source_id)['items']
    assert_equal 2, @api.creates.size
    @api.save_failure = nil
    ready_again(move)
    @worker.run
    assert_equal 'done', move.reload.state
    assert_equal binding('2026-11').id, link.invoice_binding_id
    assert_equal 5, @api.reports.fetch(target_id)['items'][0]['hours']
    assert_equal [], @api.reports.fetch(source_id)['items']
    assert_equal 2, @api.creates.size
  end

  def test_move_between_projects_keeps_client_and_invoice_bindings_separate
    enqueue
    @worker.run
    other = Project.create!(name: 'Other')
    MyuctoProjectSetting.create!(project: other, client_id: 9, enabled: true)
    enqueue(1, project_id: other.id, project_name: other.name, client_id: 9)
    @worker.run
    assert_equal binding('2026-10', other).id, link.invoice_binding_id
    assert_equal [7, 9], @api.creates.map { |data| data[:client_id] }
    assert_equal [], @api.reports.fetch(binding.invoice_id)['items']
  end

  def test_move_recovers_when_target_save_succeeds_but_its_response_is_lost
    enqueue
    @worker.run
    source_id = binding.invoice_id
    lost_response = false
    @api.define_singleton_method(:save_work_report) do |id, report|
      result = super(id, report)
      if id != source_id && !lost_response
        lost_response = true
        raise Myucto::Unavailable, 'Response lost after save'
      end
      result
    end
    event = enqueue(1, spent_on: '2026-11-01', hours: 6)
    @worker.run
    assert_equal 'pending', event.reload.state
    target_id = binding('2026-11').invoice_id
    assert_equal 1, @api.reports.fetch(target_id)['items'].size
    writes = @api.writes.size
    ready_again(event)
    @worker.run
    assert_equal 'done', event.reload.state
    assert_equal binding('2026-11').id, link.invoice_binding_id
    assert_equal writes, @api.writes.size
    assert_equal 1, @api.reports.fetch(target_id)['items'].size
    assert_equal 2, @api.creates.size
  end

  def test_uncertain_create_blocks_reposting_even_after_event_is_retried
    @api.create_failure = Myucto::UncertainCreate.new('Response lost after creation')
    event = enqueue
    @worker.run
    assert_equal 'conflict', event.reload.state
    assert_equal 'uncertain', binding.state
    assert_equal 1, @api.creates.size
    assert_equal 1, @api.invoices.size
    @api.create_failure = nil
    ready_again(event)
    @worker.run
    assert_equal 'conflict', event.reload.state
    assert_equal 1, @api.creates.size
    assert_empty @api.reports
  end

  def test_crash_left_creation_intent_blocks_another_post
    MyuctoInvoiceBinding.create!(project: @project, period: '2026-10', client_id: 7, state: 'creating')
    event = enqueue
    @worker.run
    assert_equal 'conflict', event.reload.state
    assert_empty @api.creates
  end

  def test_changed_connection_cannot_edit_an_existing_binding
    enqueue
    @worker.run
    original = Myucto.configuration
    event = enqueue(1, hours: 4)
    writes = @api.writes.size
    alternate = original.merge('supplier_id' => '99')
    Myucto.stub(:configuration, alternate) { @worker.run }
    assert_equal 'conflict', event.reload.state
    assert_equal writes, @api.writes.size
    assert_equal 2, @api.reports.fetch(binding.invoice_id)['items'][0]['hours']
  end

  def test_unfinished_predecessor_blocks_newer_event_for_same_entry
    first = enqueue
    first.update!(available_at: Time.current + 600)
    second = enqueue(1, hours: 7)
    unrelated = enqueue(2)
    assert_equal 1, @worker.run
    assert_equal 'pending', first.reload.state
    assert_equal 'pending', second.reload.state
    assert_equal 'done', unrelated.reload.state
    ready_again(first)
    assert_equal 2, @worker.run
    assert_equal 'done', second.reload.state
    own = @api.reports.fetch(binding.invoice_id)['items'].find { |row| row['description'].end_with?('[TE#1]') }
    assert_equal 7, own['hours']
  end

  def test_conflicted_predecessor_blocks_later_delete
    enqueue
    @worker.run
    @api.reports.fetch(binding.invoice_id)['items'][0]['description'] = 'Manually edited [TE#1]'
    edit = enqueue(1, hours: 4)
    deletion = enqueue(1, deleted: true)
    @worker.run
    assert_equal 'conflict', edit.reload.state
    assert_equal 'pending', deletion.reload.state
    assert_equal 'Manually edited [TE#1]', @api.reports.fetch(binding.invoice_id)['items'][0]['description']
  end

  def test_existing_link_is_protected_after_source_project_is_disabled
    enqueue
    @worker.run
    @setting.update!(enabled: false)
    @api.invoices.fetch(binding.invoice_id)['status'] = 'issued'
    deletion = enqueue(1, deleted: true)
    writes = @api.writes.size
    @worker.run
    assert_equal 'conflict', deletion.reload.state
    assert_equal 'synced', link.state
    assert_equal writes, @api.writes.size
    assert_equal 1, @api.reports.fetch(binding.invoice_id)['items'].size
  end

  def test_transient_failure_retries_then_stops_after_eight_attempts
    enqueue
    @worker.run
    @api.save_failure = ->(_id, _report) { raise Myucto::Unavailable, 'Temporary outage' }
    event = enqueue(1, hours: 4)
    8.times do |attempt|
      ready_again(event)
      @worker.run
      assert_equal attempt + 1, event.reload.attempts
      assert_equal(attempt == 7 ? 'failed' : 'pending', event.state)
    end
    assert_equal 2, @api.reports.fetch(binding.invoice_id)['items'][0]['hours']
    assert_equal 1, @api.creates.size
  end

  def test_database_unique_indexes_prevent_duplicate_binding_and_time_link
    enqueue
    @worker.run
    assert_raises(ActiveRecord::RecordNotUnique) do
      MyuctoInvoiceBinding.insert_all!([{ project_id: @project.id, period: '2026-10', client_id: 7, state: 'pending', created_at: Time.current, updated_at: Time.current }])
    end
    assert_raises(ActiveRecord::RecordNotUnique) do
      MyuctoTimeLink.insert_all!([{ time_entry_id: 1, state: 'pending', created_at: Time.current, updated_at: Time.current }])
    end
  end
end
