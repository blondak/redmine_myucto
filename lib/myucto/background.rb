# frozen_string_literal: true

require 'securerandom'

module Myucto
  # ActiveJob contains only disposable wake-ups. Events, order, backoff and
  # completion remain in SQL; no AR objects or API clients survive a job.
  class Background
    POLL_INTERVAL = 60
    BATCH_SIZE = 10
    STALE_WAKEUP = POLL_INTERVAL * 2

    class << self
      def enabled?
        !%w[0 false off].include?(ENV.fetch('MYUCTO_AUTO_SYNC', '1').downcase)
      end

      def start!
        return unless enabled?
        # A fork must never inherit the parent's adapter, mutex or scheduled jobs.
        if @pid != Process.pid
          @pid = Process.pid
          @guard = Mutex.new
          @instance = nil
        end
        @guard.synchronize do
          @instance ||= new
          @instance.start
        end
      rescue StandardError => e
        log_error(e)
      end

      def wake!(at: Time.now)
        return unless enabled? && @pid == Process.pid
        @instance&.wake(at: at)
      rescue StandardError => e
        # The event has already committed. A scheduling failure must not make
        # Redmine report a failed save; the periodic refill will pick it up.
        log_error(e)
      end

      def perform(kind, generation, ticket)
        return unless enabled? && @pid == Process.pid
        @instance&.perform(kind, generation, ticket)
      end

      def stop!(wait: true)
        @instance&.stop(wait: wait) if @pid == Process.pid
        @instance = nil
      end

      def build_adapter
        ActiveJob::QueueAdapters::AsyncAdapter.new(
          min_threads: 0, max_threads: 1, idletime: 60, fallback_policy: :abort
        )
      end

      def build_watchdog(&block)
        require 'concurrent/timer_task'
        Concurrent::TimerTask.new(execution_interval: POLL_INTERVAL, &block).execute
      end

      def log_error(error)
        # Exception text can contain connection details. Log only the class.
        Rails.logger.error("MyUcto background scheduling failed (#{error.class.name})") if defined?(Rails)
      end
    end

    def initialize
      @mutex = Mutex.new
      @generation = SecureRandom.hex(16)
      @adapter = self.class.build_adapter
      MyuctoSyncJob.queue_adapter = @adapter
      @poll_ticket = 0
      @drain_ticket = 0
      @stopped = false
    end

    def start
      @mutex.synchronize do
        return if @stopped
        # Independent of the ActiveJob queue: if enqueue fails or a wrapper
        # fails before calling perform, the idle process still repairs itself.
        # This timer only enqueues work; all SQL/HTTP runs in the Async job.
        @watchdog ||= self.class.build_watchdog { start }
        return if @poll_scheduled && @poll_at > Time.now - STALE_WAKEUP
        schedule_poll(Time.now)
      end
    rescue StandardError => e
      self.class.log_error(e)
    end

    def wake(at: Time.now)
      at = Time.at(at.to_f)
      @mutex.synchronize do
        return if @stopped
        if @running
          @requested_at = [@requested_at, at].compact.min
        else
          schedule_drain(at)
        end
      end
    end

    def perform(kind, generation, ticket)
      return if generation != @generation
      case kind
      when 'poll' then poll(ticket)
      when 'drain' then drain(ticket)
      end
    end

    def stop(wait: true)
      @mutex.synchronize { @stopped = true }
      @watchdog.shutdown if @watchdog.respond_to?(:shutdown)
      @adapter.shutdown(wait: wait) if @adapter.respond_to?(:shutdown)
    end

    private

    def enqueue(kind, ticket, at)
      # app/jobs can be reloaded while the process-local dispatcher survives.
      # Reapply the dedicated adapter instead of inheriting a global/inline one.
      MyuctoSyncJob.queue_adapter = @adapter unless MyuctoSyncJob.queue_adapter.equal?(@adapter)
      job = MyuctoSyncJob.new(kind, @generation, ticket)
      result = at <= Time.now ? job.enqueue : job.enqueue(wait_until: at)
      raise 'MyUcto background job was not enqueued' unless result
    end

    # All schedule helpers run under the mutex. The dedicated Async adapter
    # never executes inline (including during shutdown).
    def schedule_poll(at)
      @poll_ticket += 1
      @poll_scheduled = false
      enqueue('poll', @poll_ticket, at)
      @poll_at = at
      @poll_scheduled = true
    end

    def schedule_drain(at)
      return if @drain_at && @drain_at <= at && @drain_at > Time.now - STALE_WAKEUP
      @drain_ticket += 1
      @drain_at = nil
      enqueue('drain', @drain_ticket, at)
      @drain_at = at
    end

    def poll(ticket)
      accepted = @mutex.synchronize do
        next false if @stopped || ticket != @poll_ticket || !@poll_scheduled
        @poll_scheduled = false
        true
      end
      return unless accepted

      begin
        wake
      ensure
        @mutex.synchronize { schedule_poll(Time.now + POLL_INTERVAL) unless @stopped }
      end
    rescue StandardError => e
      self.class.log_error(e)
    end

    def drain(ticket)
      accepted = @mutex.synchronize do
        next false if @stopped || @running || ticket != @drain_ticket || !@drain_at
        @drain_at = nil
        @running = true
        @requested_at = nil
        true
      end
      return unless accepted

      next_at = nil
      begin
        Setting.check_cache if defined?(Setting)
        # Do not instantiate an API client when nothing is ready or setup has
        # not finished yet (including plugin migrations).
        if MyuctoSyncEvent.table_exists?
          Worker.new.run(limit: BATCH_SIZE) if MyuctoSyncEvent.unblocked.ready.exists?
          row = MyuctoSyncEvent.unblocked.where(state: 'pending')
            .order(Arel.sql('CASE WHEN available_at IS NULL THEN 0 ELSE 1 END'), :available_at)
            .pick(:id, :available_at)
          next_at = row && (row[1] || Time.now)
        end
      rescue StandardError => e
        # The poll chain is independent of drain failures, including DB outage
        # and missing API configuration. No busy retry loop or lost event.
        self.class.log_error(e)
      ensure
        @mutex.synchronize do
          @running = false
          at = [next_at, @requested_at].compact.min
          @requested_at = nil
          # Long waits are recovered by the regular refill instead of keeping
          # arbitrarily many delayed jobs in the in-memory adapter.
          schedule_drain(at) if !@stopped && at && at <= Time.now + POLL_INTERVAL
        end
      end
    rescue StandardError => e
      self.class.log_error(e)
    end
  end
end
