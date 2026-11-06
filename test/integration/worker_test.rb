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


  def select_template
    @setting.update!(billing_template_id: 12)
    @template = { 'id' => 12, 'name' => 'Support', 'currency' => 'EUR',
                  'fixed_fee' => 100, 'included_hours' => 2, 'fixed_description' => '{obdobi}',
                  'bands' => [{ 'up_to_hours' => nil, 'rate' => 50, 'description' => 'Work' }] }
    template = @template
    @api.define_singleton_method(:billing_templates) { [template] }
  end

  def test_template_applied_to_new_report_and_existing_agreement_preserved
    select_template
    event = enqueue
    @worker.run
    assert_equal 'done', event.reload.state, event.last_error
    assert_equal 'EUR', @api.creates.first[:currency]
    report = @api.reports.fetch(binding.invoice_id)
    assert_equal 12, report['billing_template_id']
    assert_equal '2026-10', report['billing_period']
    assert_equal 100, report['billing_snapshot']['fixed_fee']
    report['billing_snapshot']['fixed_fee'] = 999
    @setting.update!(billing_template_id: nil)
    update = enqueue(1, hours: 3)
    @worker.run
    assert_equal 'done', update.reload.state, update.last_error
    assert_equal 999, @api.reports.fetch(binding.invoice_id)['billing_snapshot']['fixed_fee']
    refute @api.writes.last[1].key?('billing_snapshot')
    next_month = enqueue(2, spent_on: '2026-11-02')
    @worker.run
    assert_equal 'done', next_month.reload.state
    refute @api.reports.fetch(binding('2026-11').invoice_id).key?('billing_template_id')
  end

  def test_retry_uses_persisted_template_after_explicit_create_failure
    select_template
    @api.create_failure = Myucto::Unavailable.new('rejected')
    event = enqueue
    @worker.run
    assert_equal 'pending', binding.state
    @template['fixed_fee'] = 500
    @setting.update!(billing_template_id: nil)
    @api.create_failure = nil
    ready_again(event)
    @worker.run
    assert_equal 'done', event.reload.state, event.last_error
    assert_equal 100, @api.reports.fetch(binding.invoice_id)['billing_snapshot']['fixed_fee']
    assert_equal 'EUR', @api.creates.last[:currency]
  end

  def test_removing_last_time_preserves_billing_agreement
    select_template
    enqueue
    @worker.run
    event = enqueue(1, deleted: true)
    @worker.run
    assert_equal 'done', event.reload.state, event.last_error
    report = @api.reports.fetch(binding.invoice_id)
    assert_empty report['items']
    assert_equal 12, report['billing_template_id']
    assert_equal 100, report['billing_snapshot']['fixed_fee']
    assert_equal 1, @api.creates.size
  end

  def test_existing_month_never_receives_new_project_template
    enqueue
    @worker.run
    select_template
    event = enqueue(2)
    @worker.run
    assert_equal 'done', event.reload.state, event.last_error
    assert_nil binding.billing_template_id
    refute @api.reports.fetch(binding.invoice_id).key?('billing_snapshot')
  end

  def test_missing_template_does_not_create_invoice
    @setting.update!(billing_template_id: 12)
    @api.define_singleton_method(:billing_templates) { [] }
    event = enqueue
    @worker.run
    assert_equal 'conflict', event.reload.state
    assert_empty @api.creates
    assert_equal 0, MyuctoInvoiceBinding.count
  end

  def test_lost_first_report_response_does_not_replace_template_on_retry
    select_template
    event = enqueue
    fired = false
    @api.save_failure = lambda do |id, report|
      unless fired
        fired = true
        @api.reports[id] = @api.copy(report)
        raise Myucto::Unavailable, 'lost response'
      end
    end
    @worker.run
    @api.reports.fetch(binding.invoice_id)['billing_snapshot']['fixed_fee'] = 800
    ready_again(event)
    @worker.run
    assert_equal 'done', event.reload.state, event.last_error
    assert_equal 1, @api.creates.size
    assert_equal 800, @api.reports.fetch(binding.invoice_id)['billing_snapshot']['fixed_fee']
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
    assert_equal 'pending', event.reload.state
    assert_equal 1, event.attempts
    assert_operator event.available_at, :>, Time.current
    assert_empty @api.creates
    7.times do
      ready_again(event)
      @worker.run
    end
    assert_equal 'failed', event.reload.state
    assert_equal 8, event.attempts
    assert_equal 'creating', binding.state
    assert_empty @api.creates
  end

  def test_duplicate_poll_during_create_defers_other_entry_without_another_post
    first = enqueue
    second = enqueue(2)
    other_worker = Myucto::Worker.new(client: @api)
    nested_processed = nil
    @api.define_singleton_method(:create_invoice) do |**attributes|
      nested_processed = other_worker.run
      super(**attributes)
    end
    assert_equal 1, @worker.run
    assert_equal 1, nested_processed
    assert_equal 'done', first.reload.state
    assert_equal 'pending', second.reload.state
    assert_equal 1, second.attempts
    assert_equal 1, @api.creates.size
    ready_again(second)
    assert_equal 1, other_worker.run
    assert_equal 'done', second.reload.state
    assert_equal 1, @api.creates.size
    assert_equal 2, @api.reports.fetch(binding.invoice_id)['items'].size
  end

  def test_losing_event_claim_does_not_process_an_already_claimed_event
    event = enqueue
    original = MyuctoSyncEvent.method(:where)
    claim_stolen = false
    interleaved_where = lambda do |*args|
      if !claim_stolen && args.first == { id: event.id, state: 'pending' }
        claim_stolen = true
        original.call(id: event.id).update_all(state: 'processing')
      end
      original.call(*args)
    end
    MyuctoSyncEvent.stub(:where, interleaved_where) do
      assert_equal 0, @worker.run
    end
    assert claim_stolen
    assert_equal 'processing', event.reload.state
    assert_empty @api.creates
    assert_empty @api.writes
    assert_equal 0, MyuctoTimeLink.count
  end

  def test_binding_validation_race_reuses_competing_binding
    event = enqueue
    original = MyuctoInvoiceBinding.method(:create_or_find_by!)
    competing_id = nil
    interleaved_create = lambda do |attributes, &block|
      competitor = MyuctoInvoiceBinding.create!(attributes.merge(client_id: 7, connection_key: Myucto.connection_key))
      competing_id = competitor.id
      # The real uniqueness validator now sees the competing committed row.
      original.call(attributes, &block)
    end
    MyuctoInvoiceBinding.stub(:create_or_find_by!, interleaved_create) { @worker.run }
    assert_equal 'done', event.reload.state, event.last_error
    assert_equal competing_id, binding.id
    assert_equal 1, MyuctoInvoiceBinding.count
    assert_equal 1, @api.creates.size
  end

  def test_losing_event_claim_respects_retry_scheduled_by_another_worker
    event = enqueue
    original = MyuctoSyncEvent.method(:where)
    deferred = false
    interleaved_where = lambda do |*args|
      if !deferred && args.first == { id: event.id, state: 'pending' }
        deferred = true
        original.call(id: event.id).update_all(available_at: Time.current + 600, attempts: 1)
      end
      original.call(*args)
    end
    MyuctoSyncEvent.stub(:where, interleaved_where) { assert_equal 0, @worker.run }
    assert deferred
    assert_equal 'pending', event.reload.state
    assert_equal 1, event.attempts
    assert_empty @api.creates
  end

  def test_binding_race_does_not_swallow_other_validation_errors
    data = enqueue(1, client_id: 0).payload_data
    original = MyuctoInvoiceBinding.method(:create_or_find_by!)
    interleaved_create = lambda do |attributes, &block|
      MyuctoInvoiceBinding.create!(attributes.merge(client_id: 7))
      original.call(attributes, &block)
    end
    MyuctoInvoiceBinding.stub(:create_or_find_by!, interleaved_create) do
      error = assert_raises(ActiveRecord::RecordInvalid) { @worker.send(:binding_for, data) }
      assert_includes error.record.errors.attribute_names, :client_id
      assert_includes error.record.errors.attribute_names, :period
    end
    assert_empty @api.creates
  end

  def test_binding_validation_race_checks_competitors_connection
    event = enqueue
    original = MyuctoInvoiceBinding.method(:create_or_find_by!)
    interleaved_create = lambda do |attributes, &block|
      MyuctoInvoiceBinding.create!(attributes.merge(client_id: 7, connection_key: 'different-connection'))
      original.call(attributes, &block)
    end
    MyuctoInvoiceBinding.stub(:create_or_find_by!, interleaved_create) { @worker.run }
    assert_equal 'conflict', event.reload.state
    assert_empty @api.creates
  end

  def test_losing_creation_claim_reloads_successful_invoice_without_posting
    invoice_binding = MyuctoInvoiceBinding.create!(project: @project, period: '2026-10', client_id: 7)
    @api.invoices[777] = { 'id' => 777, 'status' => 'draft', 'items' => [] }
    event = enqueue
    with_competing_creation_claim(invoice_binding, state: 'ready', invoice_id: 777) { @worker.run }
    assert_equal 'done', event.reload.state, event.last_error
    assert_equal 777, link.invoice_binding.invoice_id
    assert_empty @api.creates
    assert_equal 1, @api.reports.fetch(777)['items'].size
  end

  def test_losing_creation_claim_defers_while_other_worker_is_creating
    invoice_binding = MyuctoInvoiceBinding.create!(project: @project, period: '2026-10', client_id: 7)
    event = enqueue
    with_competing_creation_claim(invoice_binding, state: 'creating') { @worker.run }
    assert_equal 'pending', event.reload.state
    assert_equal 1, event.attempts
    assert_equal 'creating', invoice_binding.reload.state
    assert_empty @api.creates
  end

  def test_losing_creation_claim_cannot_bypass_manual_recovery_states
    %w[uncertain conflict].each_with_index do |state, index|
      period = "2026-#{10 + index}"
      invoice_binding = MyuctoInvoiceBinding.create!(project: @project, period: period, client_id: 7)
      event = enqueue(index + 1, spent_on: "#{period}-01")
      with_competing_creation_claim(invoice_binding, state: state) { @worker.run }
      assert_equal 'conflict', event.reload.state
      assert_equal state, invoice_binding.reload.state
      assert_empty @api.creates
    end
  end

  def test_inconsistent_creation_states_never_post_again
    [{ state: 'ready', invoice_id: nil }, { state: 'pending', invoice_id: 888 }].each_with_index do |attributes, index|
      period = "2026-#{10 + index}"
      MyuctoInvoiceBinding.create!(attributes.merge(project: @project, period: period, client_id: 7))
      event = enqueue(index + 1, spent_on: "#{period}-01")
      @worker.run
      assert_equal 'conflict', event.reload.state
      assert_empty @api.creates
    end
  end

  def with_competing_creation_claim(invoice_binding, **changes)
    original = MyuctoInvoiceBinding.method(:where)
    interleaved = false
    interleaved_where = lambda do |*args|
      if !interleaved && args.first == { id: invoice_binding.id, state: 'pending', invoice_id: nil }
        interleaved = true
        original.call(id: invoice_binding.id).update_all(changes)
      end
      original.call(*args)
    end
    MyuctoInvoiceBinding.stub(:where, interleaved_where) { yield }
    assert interleaved, 'The competing claim must run between reload and conditional UPDATE'
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
