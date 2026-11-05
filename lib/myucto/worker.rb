# frozen_string_literal: true
require 'json'
require 'date'

module Myucto
  class Worker
    def initialize(client: Client.new)
      @client = client
      @synchronizer = Synchronizer.new(client: client)
    end

    def run(limit: 100)
      processed = 0
      table = MyuctoSyncEvent.connection.quote_table_name(MyuctoSyncEvent.table_name)
      eligible = MyuctoSyncEvent.ready.where("NOT EXISTS (SELECT 1 FROM #{table} prior_event WHERE prior_event.time_entry_id = #{table}.time_entry_id AND prior_event.id < #{table}.id AND prior_event.state <> 'done')")
      while processed < limit
        event = eligible.order(:id).first
        break unless event
        # A later change must never overtake an unfinished create/move/delete.
        next if MyuctoSyncEvent.where(time_entry_id: event.time_entry_id).where('id < ?', event.id).where.not(state: 'done').exists?
        claimed = MyuctoSyncEvent.where(id: event.id, state: 'pending').update_all(state: 'processing', updated_at: Time.current)
        next unless claimed == 1
        event.reload
        begin
          process(event)
          event.update!(state: 'done', last_error: nil)
        rescue UncertainCreate, Conflict => e
          event.update!(state: 'conflict', last_error: e.message)
        rescue Unavailable => e
          attempts = event.attempts + 1
          event.update!(state: attempts >= 8 ? 'failed' : 'pending', attempts: attempts,
                        available_at: Time.current + [30 * (2**[attempts, 10].min), 3600].min,
                        last_error: e.message)
        rescue Error, ArgumentError => e
          event.update!(state: 'failed', attempts: event.attempts + 1, last_error: e.message)
        rescue StandardError => e
          # Do not expose request payloads, tokens or database exception details.
          event.update!(state: 'failed', attempts: event.attempts + 1,
                        last_error: "Internal synchronization error (#{e.class.name})")
        end
        processed += 1
      end
      processed
    end

    private

    def process(event)
      @verified ||= @client.verify_connection!
      data = event.payload_data
      link = MyuctoTimeLink.find_or_create_by!(time_entry_id: event.time_entry_id)
      source = link.invoice_binding
      Myucto.assert_connection!(source) if source
      target = data['deleted'] ? nil : binding_for(data)
      ensure_invoice!(target, data) if target
      # Locks cover the read/merge/write AND its local checkpoint. Stable ordering
      # avoids deadlocks for opposing cross-project/month moves.
      sync_error = nil
      with_bindings_locked([source, target].compact.uniq(&:id).sort_by(&:id)) do
        begin
          link.reload
          [source, target].compact.each do |binding|
            Myucto.assert_editable!(@client.invoice(binding.invoice_id), binding.invoice_id) if binding.invoice_id
          end
          if source && source.id != target&.id && link.state != 'removed'
            remote_row = (@client.work_report(source.invoice_id) || {}).fetch('items', []).find { |row| row['description'].to_s.end_with?("[TE##{event.time_entry_id}]") }
            carried = (link.synced_payload_data || {}).dup
            carried['rate'] = remote_row['rate'] if remote_row
            @synchronizer.reconcile(invoice_id: source.invoice_id, time_entry_id: event.time_entry_id,
                                    desired: nil, previous: link.synced_payload_data)
            link.update!(state: 'removed', synced_payload: JSON.generate(carried))
          end
          if target
            row = {
              'description' => data.fetch('description'), 'work_date' => data.fetch('spent_on'),
              'hours' => data.fetch('hours').to_f.round(2),
              'rate' => (link.synced_payload_data || {}).fetch('rate', 0)
            }
            prior = source&.id == target.id && link.state != 'removed' ? link.synced_payload_data : nil
            synced = @synchronizer.reconcile(invoice_id: target.invoice_id, time_entry_id: event.time_entry_id,
                                             desired: row, previous: prior,
                                             title: "#{data.fetch('project_name')} — #{target.period}")
            link.update!(invoice_binding_id: target.id, synced_payload: JSON.generate(synced), state: 'synced')
          else
            link.update!(invoice_binding_id: nil, synced_payload: nil, state: 'deleted')
          end
        rescue Myucto::Error, ArgumentError => e
          # Commit a completed source removal before reporting a target failure.
          sync_error = e
        end
      end
      raise sync_error if sync_error
    end

    def binding_for(data)
      project_id = data.fetch('project_id')
      period = Date.iso8601(data.fetch('spent_on')).strftime('%Y-%m')
      existing = MyuctoInvoiceBinding.find_by(project_id: project_id, period: period)
      if existing
        Myucto.assert_connection!(existing)
        return existing
      end
      setting = MyuctoProjectSetting.find_by(project_id: project_id, enabled: true)
      authorized = data.key?('integration_enabled') ? data['integration_enabled'] : !!setting
      raise Conflict, 'Target project has no enabled MyÚčto integration' unless authorized
      client_id = data['client_id'] || setting&.client_id
      raise Conflict, 'Target project has no MyÚčto customer' unless client_id
      MyuctoInvoiceBinding.create_or_find_by!(project_id: project_id, period: period) do |binding|
        binding.client_id = client_id
        binding.connection_key = Myucto.connection_key
      end
    end

    def ensure_invoice!(binding, data)
      binding.reload
      return if binding.invoice_id && binding.state == 'ready'
      if %w[creating uncertain conflict].include?(binding.state)
        raise Conflict, "Invoice creation needs verification for #{binding.period} (binding ##{binding.id})"
      end
      # Commit intent BEFORE any HTTP call. A crash leaves 'creating' and MUST NOT
      # cause a second POST. No surrounding database transaction is permitted here.
      claimed = MyuctoInvoiceBinding.where(id: binding.id, state: 'pending', invoice_id: nil)
                                   .update_all(state: 'creating', updated_at: Time.current)
      raise Conflict, 'Invoice creation is already in progress' unless claimed == 1
      begin
        invoice = @client.create_invoice(client_id: binding.client_id, period: binding.period,
                                         project_name: data.fetch('project_name'))
        binding.update!(invoice_id: invoice.fetch('id'), state: 'ready', error: nil)
      rescue UncertainCreate => e
        binding.update!(state: 'uncertain', error: e.message)
        raise
      rescue Error => e
        # Explicit rejection means no successful create; operator can retry event.
        binding.update!(state: 'pending', error: e.message)
        raise
      end
    end

    def with_bindings_locked(bindings, &block)
      return yield if bindings.empty?
      bindings.first.with_lock do
        with_bindings_locked(bindings.drop(1), &block)
      end
    end
  end
end
