# frozen_string_literal: true
module Myucto
  module TimelogControllerPatch
    def self.included(base)
      base.after_action :myucto_explain_refused_deletion, only: :destroy
    end

    private

    # Redmine 6 HTML destroy replaces model errors with a generic notice. Preserve
    # the specific refusal; API destroy already renders model validation errors.
    def myucto_explain_refused_deletion
      return unless request.format.html?
      reasons = Array(@time_entries).filter_map(&:myucto_refusal_message).uniq
      flash[:error] = reasons.join(' ') unless reasons.empty?
    end
  end
end
