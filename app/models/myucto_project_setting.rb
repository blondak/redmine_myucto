require 'json'

class MyuctoProjectSetting < ActiveRecord::Base
  belongs_to :project, class_name: 'Project', foreign_key: :project_id

  validate :validate_allowed_user_ids

  validates :project_id, presence: true, uniqueness: true
  validates :client_id, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :billing_template_id, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :client_id, presence: true, if: :enabled?

  def allowed_user_ids
    allowed_user_ids_json.present? ? JSON.parse(allowed_user_ids_json) : []
  end

  def allowed_user_ids=(values)
    ids = Array(values).reject { |value| value.to_s.empty? }.map do |value|
      value.to_s.match?(/\A[1-9]\d*\z/) ? value.to_i : value
    end
    self.allowed_user_ids_json = JSON.generate(ids.uniq)
  end

  def transfer_user?(user_id)
    enabled? && allowed_user_ids.include?(user_id)
  end

  private

  def validate_allowed_user_ids
    ids = allowed_user_ids
    unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(Integer) && id.positive? }
      errors.add(:allowed_user_ids, :invalid)
    end
  rescue JSON::ParserError
    errors.add(:allowed_user_ids, :invalid)
  end
end
