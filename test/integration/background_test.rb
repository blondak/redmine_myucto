# frozen_string_literal: true

require_relative 'helper'
require 'active_job'
require 'active_job/queue_adapters/test_adapter'
require 'active_support/testing/time_helpers'
require 'minitest/mock'
require 'logger'
require_relative '../../app/jobs/myucto_sync_job'

# Execute real serialized jobs deterministically; the in-memory SQLite database
# is intentionally never accessed by a test background thread.
class BackgroundIntegrationTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  class Watchdog
    attr_reader :stopped

    def initialize(&tick)
      @tick = tick
      @stopped = false
    end

    def tick
      @tick.call unless stopped
    end

    def shutdown
      @stopped = true
    end
  end

  def setup
    Myucto::Background.stop!
    @previous_auto_sync = ENV['MYUCTO_AUTO_SYNC']
    ENV['MYUCTO_AUTO_SYNC'] = '1'
    @previous_adapter = MyuctoSyncJob.queue_adapter
    @previous_logger = ActiveJob::Base.logger
    ActiveJob::Base.logger = Logger.new(File::NULL)
    @adapter = ActiveJob::QueueAdapters::TestAdapter.new
    @watchdogs = []
    [MyuctoSyncEvent, MyuctoTimeLink, MyuctoInvoiceBinding, MyuctoProjectSetting, TimeEntry, Project].each(&:delete_all)
    @project = Project.create!(name: 'Background example')
    MyuctoProjectSetting.create!(project: @project, client_id: 7, enabled: true)
    @api = WorkerApi.new
    @worker = Myucto::Worker.new(client: @api)
    travel_to Time.utc(2026, 11, 5, 12)
  end

  def teardown
    Myucto::Background.stop!
    assert @watchdogs.all?(&:stopped), 'Stopping the dispatcher must stop every watchdog created by this test'
    MyuctoSyncJob.queue_adapter = @previous_adapter
    ActiveJob::Base.logger = @previous_logger
    if @previous_auto_sync.nil?
      ENV.delete('MYUCTO_AUTO_SYNC')
    else
      ENV['MYUCTO_AUTO_SYNC'] = @previous_auto_sync
    end
    travel_back
  end

  def enqueue(id = 1, **attributes)
    data = { 'project_id' => @project.id, 'project_name' => @project.name, 'client_id' => 7,
             'spent_on' => '2026-11-05', 'hours' => 2, 'description' => "Task #{id}" }
    MyuctoSyncEvent.create!({ time_entry_id: id, project_id: @project.id,
                            payload: JSON.generate(data), state: 'pending' }.merge(attributes))
  end

  def start
    build_watchdog = lambda do |&tick|
      Watchdog.new(&tick).tap { |watchdog| @watchdogs << watchdog }
    end
    Myucto::Background.stub(:build_watchdog, build_watchdog) do
      Myucto::Background.stub(:build_adapter, @adapter) { Myucto::Background.start! }
    end
  end

  def jobs(kind)
    @adapter.enqueued_jobs.select { |job| job.fetch('arguments').first == kind }
  end

  def execute(kind, job: nil)
    job ||= jobs(kind).find { |candidate| !candidate[:at] || candidate[:at] <= Time.now.to_f }
    refute_nil job, "Expected a due #{kind} job"
    @adapter.enqueued_jobs.delete(job)
    Myucto::Worker.stub(:new, @worker) { ActiveJob::Base.execute(job) }
    job
  end

  def test_start_refills_durable_outbox_and_uses_its_own_adapter
    event = enqueue
    original_global_adapter = ActiveJob::Base.queue_adapter
    3.times { start }
    assert_same original_global_adapter, ActiveJob::Base.queue_adapter
    assert_same @adapter, MyuctoSyncJob.queue_adapter
    assert_equal 1, jobs('poll').size
    assert_empty jobs('drain')
    execute('poll')
    assert_equal 1, jobs('drain').size
    assert_equal 1, jobs('poll').size
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
    assert_equal 1, @api.reports.values.first.fetch('items').size
  end

  def test_outbox_wake_occurs_only_after_transaction_commits
    start
    event = nil
    MyuctoSyncEvent.transaction do
      event = enqueue
      assert_empty jobs('drain')
      assert_equal 'pending', event.state
    end
    assert_equal 1, jobs('drain').size
    execute('drain')
    assert_equal 'done', event.reload.state
  end

  def test_rolled_back_outbox_does_not_wake_or_transfer
    start
    MyuctoSyncEvent.transaction do
      enqueue
      assert_empty jobs('drain')
      raise ActiveRecord::Rollback
    end
    assert_equal 0, MyuctoSyncEvent.count
    assert_empty jobs('drain')
    execute('poll')
    execute('drain')
    assert_empty @api.creates
    assert_empty @api.writes
  end

  def test_periodic_refill_reaches_future_pending_without_another_request
    due_at = Time.current + 180
    event = enqueue(1, available_at: due_at)
    start
    execute('poll')
    execute('drain')
    assert_empty @api.creates
    assert_empty jobs('drain')
    3.times do
      travel_to Time.current + 60
      execute('poll')
      execute('drain')
    end
    assert_equal due_at, Time.current
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
  end

  def test_transient_worker_failure_obeys_durable_backoff_and_then_retries
    event = enqueue
    @api.save_failure = ->(_id, _report) { raise Myucto::Unavailable, 'Temporary outage' }
    start
    execute('poll')
    execute('drain')
    event.reload
    assert_equal 'pending', event.state
    assert_equal 1, event.attempts
    assert_equal Time.current + 60, event.available_at
    assert_equal [event.available_at.to_f], jobs('drain').map { |job| job[:at] }
    @api.save_failure = nil
    travel_to Time.current + 59
    assert jobs('drain').none? { |job| !job[:at] || job[:at] <= Time.now.to_f }
    assert_equal 'pending', event.reload.state
    travel_to Time.current + 1
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
    assert_equal 1, @api.reports.values.first.fetch('items').size
  end

  def test_duplicate_wakes_and_duplicate_poll_delivery_do_not_duplicate_work
    event = enqueue
    start
    poll = execute('poll')
    10.times { Myucto::Background.wake! }
    assert_equal 1, jobs('drain').size
    assert_equal 1, jobs('poll').size
    execute('poll', job: poll)
    assert_equal 1, jobs('drain').size
    assert_equal 1, jobs('poll').size
    drain = execute('drain')
    execute('drain', job: drain)
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
    assert_equal 1, @api.writes.size
  end

  def test_earlier_wake_replaces_delayed_ticket_and_old_ticket_cannot_run
    event = enqueue
    start
    Myucto::Background.wake!(at: Time.now + 50)
    obsolete = jobs('drain').first
    Myucto::Background.wake!(at: Time.now + 20)
    assert_equal 2, jobs('drain').size
    execute('drain', job: obsolete)
    assert_equal 'pending', event.reload.state
    assert_empty @api.creates
    travel_to Time.now + 20
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
  end

  def test_restart_recovers_pending_and_ignores_old_generation_jobs
    event = enqueue
    start
    execute('poll')
    old_drain = jobs('drain').first
    Myucto::Background.stop!
    @adapter = ActiveJob::QueueAdapters::TestAdapter.new
    start
    execute('drain', job: old_drain)
    assert_equal 'pending', event.reload.state
    assert_empty @api.creates
    execute('poll')
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
  end

  def test_refill_preserves_processing_and_done_states_and_predecessor_order
    processing = enqueue(1, state: 'processing')
    later = enqueue(1)
    completed = enqueue(2, state: 'done')
    start
    2.times do |index|
      travel_to Time.current + 60 if index.positive?
      execute('poll')
      execute('drain')
    end
    assert_equal 'processing', processing.reload.state
    assert_equal 'pending', later.reload.state
    assert_equal 'done', completed.reload.state
    assert_empty @api.creates
    assert_empty @api.writes
  end

  def test_drain_exception_leaves_durable_work_for_next_independent_poll
    event = enqueue
    start
    execute('poll')
    broken_worker = Object.new
    def broken_worker.run(**)
      raise IOError, 'Synthetic connection failure'
    end
    @worker = broken_worker
    execute('drain')
    assert_equal 'pending', event.reload.state
    assert_equal 1, jobs('poll').size
    assert_empty jobs('drain')
    @worker = Myucto::Worker.new(client: @api)
    travel_to Time.current + 60
    execute('poll')
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
  end

  def test_global_disable_prevents_start_wake_and_previously_queued_execution
    event = enqueue
    start
    old_poll = jobs('poll').first
    ENV['MYUCTO_AUTO_SYNC'] = '0'
    Myucto::Background.stop!
    @adapter = ActiveJob::QueueAdapters::TestAdapter.new
    start
    Myucto::Background.wake!
    execute('poll', job: old_poll)
    assert_empty @adapter.enqueued_jobs
    assert_equal 'pending', event.reload.state
    assert_empty @api.creates
  end

  def test_batch_continuation_drains_more_than_one_batch_without_next_poll
    events = (1..11).map { |id| enqueue(id) }
    start
    execute('poll')
    execute('drain')
    assert_equal 10, events.count { |event| event.reload.state == 'done' }
    assert_equal 1, jobs('drain').size
    execute('drain')
    assert events.all? { |event| event.reload.state == 'done' }
    assert_empty jobs('drain')
    assert_equal 1, jobs('poll').size
    assert_equal 1, @api.creates.size
    assert_equal 11, @api.reports.values.first.fetch('items').size
  end

  def test_after_commit_enqueue_failure_preserves_save_and_next_poll_recovers
    start
    event = nil
    @adapter.stub(:enqueue, ->(_job) { raise IOError, 'Synthetic enqueue rejection' }) do
      event = enqueue
    end
    assert event.persisted?
    assert_equal 'pending', event.reload.state
    assert_empty jobs('drain')
    assert_equal 1, jobs('poll').size
    execute('poll')
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
  end

  def test_startup_enqueue_failure_can_be_retried_by_next_request
    event = enqueue
    @adapter.stub(:enqueue, ->(_job) { raise IOError, 'Synthetic startup rejection' }) { start }
    assert_empty @adapter.enqueued_jobs
    assert_equal 'pending', event.reload.state
    start
    execute('poll')
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
  end

  def test_poll_drain_enqueue_failure_keeps_next_poll_alive
    event = enqueue
    start
    @adapter.stub(:enqueue, ->(_job) { raise IOError, 'Synthetic drain rejection' }) do
      execute('poll')
    end
    assert_empty jobs('drain')
    assert_equal 1, jobs('poll').size
    assert_equal 'pending', event.reload.state
    travel_to Time.current + 60
    execute('poll')
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
  end

  def test_failed_poll_reschedule_can_be_restarted_by_next_request
    event = enqueue
    start
    @adapter.stub(:enqueue_at, ->(_job, _at) { raise IOError, 'Synthetic timer rejection' }) do
      execute('poll')
    end
    assert_empty jobs('poll')
    assert_equal 1, jobs('drain').size
    execute('drain')
    assert_equal 'done', event.reload.state
    start
    assert_equal 1, jobs('poll').size
    execute('poll')
    execute('drain')
    assert_equal 1, @api.creates.size
  end

  def test_enqueue_reapplies_dedicated_adapter_after_job_class_reload
    event = enqueue
    start
    global_adapter = ActiveJob::Base.queue_adapter
    MyuctoSyncJob.queue_adapter = global_adapter
    global_adapter.stub(:enqueue, ->(_job) { flunk 'MyUcto must not enqueue into the global adapter' }) do
      Myucto::Background.wake!
    end
    assert_same @adapter, MyuctoSyncJob.queue_adapter
    assert_same global_adapter, ActiveJob::Base.queue_adapter
    assert_equal 1, jobs('drain').size
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
  end

  def test_request_recovers_a_poll_lost_before_execution_and_rejects_its_ticket
    event = enqueue
    start
    lost_poll = jobs('poll').first
    @adapter.enqueued_jobs.delete(lost_poll)
    travel_to Time.current + 360
    start
    assert_equal 1, jobs('poll').size, 'An overdue lost poll must not suppress future startup attempts forever'
    execute('poll', job: lost_poll)
    assert_empty jobs('drain')
    assert_equal 'pending', event.reload.state
    execute('poll')
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
  end

  def test_periodic_poll_recovers_lost_drain_and_rejects_late_old_delivery
    event = enqueue
    start
    execute('poll')
    lost_drain = jobs('drain').first
    @adapter.enqueued_jobs.delete(lost_drain)
    travel_to Time.current + 360
    execute('poll')
    assert_equal 1, jobs('drain').size, 'An overdue lost drain must not suppress independent refill forever'
    execute('drain', job: lost_drain)
    assert_equal 'pending', event.reload.state
    assert_empty @api.creates
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
  end

  def test_watchdog_recovers_startup_enqueue_failure_without_a_web_request
    event = enqueue
    @adapter.stub(:enqueue, ->(_job) { raise IOError, 'Synthetic startup rejection' }) { start }
    assert_empty @adapter.enqueued_jobs
    assert_equal 1, @watchdogs.size
    travel_to Time.current + 60
    sql = []
    subscription = ActiveSupport::Notifications.subscribe('sql.active_record') { |*details| sql << details.last[:sql] }
    begin
      @watchdogs.first.tick
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
    assert_empty sql, 'The watchdog must only enqueue disposable wake-ups'
    assert_empty @api.creates
    assert_equal 'pending', event.reload.state
    assert_equal 1, jobs('poll').size
    execute('poll')
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
    Myucto::Background.stop!
    assert @watchdogs.first.stopped
    queued = @adapter.enqueued_jobs.size
    @watchdogs.first.tick
    assert_equal queued, @adapter.enqueued_jobs.size
  end

  def test_watchdog_recovers_lost_poll_without_request_and_invalidates_old_delivery
    event = enqueue
    start
    lost_poll = jobs('poll').first
    @adapter.enqueued_jobs.delete(lost_poll)
    travel_to Time.current + 360
    @watchdogs.first.tick
    assert_equal 1, jobs('poll').size
    assert_empty @api.creates
    assert_equal 'pending', event.reload.state
    execute('poll', job: lost_poll)
    assert_empty jobs('drain')
    execute('poll')
    execute('drain')
    assert_equal 'done', event.reload.state
    assert_equal 1, @api.creates.size
    assert_equal 1, @watchdogs.size
  end
end
