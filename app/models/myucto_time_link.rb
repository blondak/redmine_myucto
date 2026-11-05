require 'json'

class MyuctoTimeLink < ActiveRecord::Base
  belongs_to :time_entry, class_name: 'TimeEntry', foreign_key: :time_entry_id, optional: true
  belongs_to :invoice_binding, class_name: 'MyuctoInvoiceBinding', foreign_key: :invoice_binding_id, optional: true

  validates :time_entry_id, presence: true, uniqueness: true
  validates :state, presence: true

  def synced_payload_data
    synced_payload.present? ? JSON.parse(synced_payload) : nil
  end

  def synced_payload_data=(value)
    self.synced_payload = value.nil? ? nil : JSON.generate(value)
  end
end
