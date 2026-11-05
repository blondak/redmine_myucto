# frozen_string_literal: true
module Myucto
  module TimeEntryPatch
    def self.included(base)
      base.attr_reader :myucto_refusal_message
      base.validate :myucto_positive_hours
      base.validate :myucto_check_editable, on: :update
      base.before_destroy :myucto_check_destroy, prepend: true
      base.after_create :myucto_enqueue_creation
      base.after_update :myucto_enqueue_update
      base.after_destroy :myucto_enqueue_deletion
    end

    private

    def myucto_tracked?
      MyuctoTimeLink.exists?(time_entry_id: id) || MyuctoSyncEvent.exists?(time_entry_id: id)
    end

    def myucto_positive_hours
      enabled = new_record? ? MyuctoProjectSetting.exists?(project_id: project_id, enabled: true) : myucto_tracked?
      if enabled && hours && hours.to_f.round(2) <= 0
        errors.add(:hours, I18n.t(:myucto_positive_hours))
      end
    end

    def myucto_check_editable
      @myucto_refusal_message = nil
      return unless myucto_tracked?
      bindings = MyuctoInvoiceBinding.where(id: MyuctoTimeLink.where(time_entry_id: id).select(:invoice_binding_id)).to_a
      if spent_on && project_id
        target = MyuctoInvoiceBinding.find_by(project_id: project_id, period: spent_on.strftime('%Y-%m'))
        bindings << target if target
      end
      # Include queued locations: the worker may have created their invoice but
      # not yet committed a TimeLink, or a move may still await processing.
      MyuctoSyncEvent.where(time_entry_id: id).where.not(state: 'done').find_each do |event|
        data = event.payload_data
        next unless data['spent_on'] && data['project_id']
        queued = MyuctoInvoiceBinding.find_by(project_id: data['project_id'], period: data['spent_on'][0, 7])
        bindings << queued if queued
      end
      client = Myucto::Client.new
      client.verify_connection!
      bindings.uniq(&:id).each do |binding|
        Myucto.assert_connection!(binding)
        if %w[creating uncertain conflict].include?(binding.state)
          raise Myucto::Conflict, I18n.t(:myucto_binding_blocked, period: binding.period)
        end
        Myucto.assert_editable!(client.invoice(binding.invoice_id), binding.invoice_id) if binding.invoice_id
      end
    rescue Myucto::Error => e
      @myucto_refusal_message = I18n.t(:myucto_change_refused, reason: e.message)
      errors.add(:base, @myucto_refusal_message)
    end

    def myucto_check_destroy
      myucto_check_editable
      throw(:abort) if errors.any?
    end

    def myucto_enqueue_creation
      setting = MyuctoProjectSetting.find_by(project_id: project_id, enabled: true)
      myucto_enqueue(false) if setting
    end

    def myucto_enqueue_update
      myucto_enqueue(false) if myucto_tracked?
    end

    def myucto_enqueue_deletion
      myucto_enqueue(true) if myucto_tracked?
    end

    def myucto_enqueue(deleted)
      parts = []
      parts << "##{issue.id} #{issue.subject}" if issue
      parts << comments.to_s.strip unless comments.to_s.strip.empty?
      parts << activity.name.to_s if parts.empty? && activity
      payload = {
        'project_id' => project_id, 'project_name' => project.name,
        'spent_on' => spent_on.iso8601, 'hours' => hours.to_f,
        'description' => "#{parts.join(' — ')} [TE##{id}]", 'deleted' => deleted,
        'client_id' => MyuctoProjectSetting.find_by(project_id: project_id)&.client_id,
        'integration_enabled' => MyuctoProjectSetting.exists?(project_id: project_id, enabled: true)
      }
      MyuctoSyncEvent.create!(time_entry_id: id, project_id: project_id,
                              payload: JSON.generate(payload), state: 'pending', available_at: Time.current)
    end
  end
end
