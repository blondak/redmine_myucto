class MyuctoInvoiceBinding < ActiveRecord::Base
  belongs_to :project, class_name: 'Project', foreign_key: :project_id
  has_many :time_links, class_name: 'MyuctoTimeLink', foreign_key: :invoice_binding_id

  validates :project_id, presence: true
  validates :period, format: { with: /\A\d{4}-(0[1-9]|1[0-2])\z/ }, uniqueness: { scope: :project_id }
  validates :client_id, numericality: { only_integer: true, greater_than: 0 }
  validates :state, presence: true
  validates :invoice_id, uniqueness: true, allow_nil: true

  def billing_defaults
    return {} unless billing_snapshot_json.present?

    { 'billing_template_id' => billing_template_id,
      'billing_snapshot' => JSON.parse(billing_snapshot_json), 'billing_period' => period }
  end

  def automatic_retry_safe?
    !%w[conflict uncertain creating].include?(state)
  end
end
