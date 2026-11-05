namespace :redmine do
  namespace :myucto do
    desc 'Synchronize pending time entries with MyÚčto once (manual/diagnostic mode)'
    task sync: :environment do
      puts "Processed #{Myucto::Worker.new.run(limit: ENV.fetch('LIMIT', '100').to_i)} events"
    end

    desc 'Resume a stopped/conflicted event after stopping all workers and resolving its cause'
    task recover_event: :environment do
      abort 'Stop all workers first; set EVENT_ID and CONFIRM=yes' unless ENV['CONFIRM'] == 'yes'
      event = MyuctoSyncEvent.find(ENV.fetch('EVENT_ID'))
      abort 'Event is already complete' if event.state == 'done'
      event.update!(state: 'pending', available_at: Time.current, last_error: nil)
      puts 'Event queued. Uncertain invoice creation remains blocked until resolved.'
    end

    desc 'Allow a new POST only after verifying that the previous attempt created NO invoice'
    task reset_creation: :environment do
      abort 'Set BINDING_ID and CONFIRM=remote_absence_verified; stop all workers first' unless ENV['CONFIRM'] == 'remote_absence_verified'
      binding = MyuctoInvoiceBinding.find(ENV.fetch('BINDING_ID'))
      abort 'Only unresolved creation without invoice_id can be reset' unless binding.invoice_id.nil? && %w[creating uncertain].include?(binding.state)
      binding.update!(state: 'pending', error: nil)
      puts 'Creation reset. Recover the affected event explicitly.'
    end
  end
end
