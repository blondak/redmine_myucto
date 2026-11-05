# frozen_string_literal: true
module Myucto
  module ProjectsHelperPatch
    def project_settings_tabs
      tabs = super
      if @project.module_enabled?(:myucto) && User.current.allowed_to?(:manage_myucto, @project)
        tabs += [{ name: 'myucto', action: :manage_myucto,
                   partial: 'myucto_projects/settings', label: :label_myucto }]
      end
      tabs
    end

    def myucto_user_options
      users = @project.users.to_a
      selected = @myucto_setting.allowed_user_ids
      # Preserve previously selected inactive/removed members for explicit removal.
      users += User.where(id: selected - users.map(&:id)).to_a
      users.sort_by { |user| user.name.downcase }.map { |user| [user.name, user.id] }
    end

    # Used by the native settings tab and the validation-error view. Never load
    # the customer directory for users who may only view synchronization status.
    def myucto_settings_data
      return unless @project.module_enabled?(:myucto) && User.current.allowed_to?(:manage_myucto, @project)
      @myucto_setting ||= MyuctoProjectSetting.find_or_initialize_by(project_id: @project.id)
      unless defined?(@clients)
        begin
          client = Myucto::Client.new
          client.verify_connection!
          @clients = client.clients
        rescue Myucto::Error
          @clients = []
          @myucto_clients_error = l(:error_myucto_api_unavailable)
        end
      end
      options = @clients.map do |client|
        name = client['company_name'].presence || client['name'].presence || client['id']
        ["#{name} (ID #{client['id']})", client['id']]
      end
      if @myucto_setting.client_id && options.none? { |option| option[1].to_s == @myucto_setting.client_id.to_s }
        options << [l(:text_myucto_current_client, id: @myucto_setting.client_id), @myucto_setting.client_id]
      end
      [@myucto_setting, options, @myucto_clients_error]
    end
  end
end
