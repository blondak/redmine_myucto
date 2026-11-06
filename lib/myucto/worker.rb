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
      eligible = MyuctoSyncEvent.ready.unblocked
      while processed < limit
        event = eligible.order(:id).first
        break unless event
        # A later change must never overtake an unfinished create/move/delete.
        next if MyuctoSyncEvent.where(time_entry_id: event.time_entry_id).where('id < ?', event.id).where.not(state: 'done').exists?
        # A competing worker may have already failed and scheduled a future
        # retry between SELECT and UPDATE. Recheck its deadline when claiming.
        claimed = MyuctoSyncEvent.where(id: event.id, state: 'pending').ready.update_all(state: 'processing', updated_at: Time.current)
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
                                             title: "#{data.fetch('project_name')} — #{target.period}",
                                             billing_defaults: target.billing_defaults)
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
      template = if setting&.billing_template_id
                   @client.billing_templates.find { |row| row['id'].to_s == setting.billing_template_id.to_s } ||
                     raise(Conflict, 'Selected MyÚčto billing template is unavailable')
                 end
      binding = begin
        MyuctoInvoiceBinding.create_or_find_by!(project_id: project_id, period: period) do |candidate|
          candidate.client_id = client_id
          if template
            candidate.billing_template_id = template.fetch('id')
            candidate.billing_snapshot_json = JSON.generate(template.slice('name', 'currency', 'fixed_fee', 'included_hours', 'fixed_description', 'bands'))
          end
          candidate.connection_key = Myucto.connection_key
        end
      rescue ActiveRecord::RecordInvalid => e
        # A competing insert can be visible to the uniqueness validator before
        # INSERT reaches the unique index. create_or_find_by! only handles the
        # latter; never hide unrelated validation failures here.
        details = e.record.errors.details
        duplicate_period = details.keys == [:period] && details[:period].all? { |error| error[:error] == :taken }
        raise unless e.record.is_a?(MyuctoInvoiceBinding) && duplicate_period &&
                     e.record.project_id.to_s == project_id.to_s && e.record.period == period
        existing = MyuctoInvoiceBinding.find_by(project_id: project_id, period: period)
        raise unless existing
        existing
      end
      Myucto.assert_connection!(binding)
      binding
    end

    def ensure_invoice!(binding, data)
      binding.reload
      return unless creation_required?(binding)
      # Commit intent BEFORE any HTTP call. A crash leaves 'creating' and MUST NOT
      # cause a second POST. No surrounding database transaction is permitted here.
      claimed = MyuctoInvoiceBinding.where(id: binding.id, state: 'pending', invoice_id: nil)
                                   .update_all(state: 'creating', updated_at: Time.current)
      unless claimed == 1
        binding.reload
        return unless creation_required?(binding)
        raise Unavailable, 'Invoice creation state changed. Try again later.'
      end
      binding.reload # update_all bypassed dirty tracking; explicit rejection must restore pending.
      begin
        options = {}
        options[:currency] = binding.billing_defaults.fetch('billing_snapshot').fetch('currency') if binding.billing_template_id
        invoice = @client.create_invoice(**options, client_id: binding.client_id, period: binding.period,
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

    def creation_required?(binding)
      return false if binding.invoice_id && binding.state == 'ready'
      if binding.state == 'creating'
        # Another worker may still own the POST. Retry the event within its
        # normal attempt limit, but never reset this durable creation intent.
        raise Unavailable, 'Invoice creation is already in progress. Try again later.'
      end
      return true if binding.state == 'pending' && binding.invoice_id.nil?
      raise Conflict, "Invoice creation needs verification for #{binding.period} (binding ##{binding.id})"
    end

    def with_bindings_locked(bindings, &block)
      return yield if bindings.empty?
      bindings.first.with_lock do
        with_bindings_locked(bindings.drop(1), &block)
      end
    end
  end
end
