require 'json'

class MyuctoSyncEvent < ActiveRecord::Base
  belongs_to :time_entry, class_name: 'TimeEntry', foreign_key: :time_entry_id, optional: true
  belongs_to :project, class_name: 'Project', foreign_key: :project_id, optional: true

  validates :time_entry_id, :payload, :state, presence: true
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  scope :ready, -> { where(state: 'pending').where('available_at IS NULL OR available_at <= ?', Time.current) }
  scope :unblocked, -> {
    table = connection.quote_table_name(table_name)
    where("NOT EXISTS (SELECT 1 FROM #{table} prior_event WHERE prior_event.time_entry_id = #{table}.time_entry_id AND prior_event.id < #{table}.id AND prior_event.state <> 'done')")
  }

  after_commit :wake_myucto_background, on: [:create, :update]

  def payload_data
    JSON.parse(payload)
  end

  def payload_data=(value)
    self.payload = JSON.generate(value)
  end

  private

  def wake_myucto_background
    Myucto::Background.wake!(at: available_at || Time.current) if state == 'pending'
  end
end
