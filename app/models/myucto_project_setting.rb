class MyuctoProjectSetting < ActiveRecord::Base
  belongs_to :project, class_name: 'Project', foreign_key: :project_id

  validates :project_id, presence: true, uniqueness: true
  validates :client_id, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :client_id, presence: true, if: :enabled?
end
