require_relative 'lib/myucto'

Redmine::Plugin.register :redmine_myucto do
  name 'Redmine MyÚčto'
  author 'Redmine MyÚčto contributors'
  description 'Synchronizes project time entries with MyÚčto invoices.'
  version '0.1.0'
  requires_redmine version_or_higher: '6.0.0'

  settings default: { 'base_url' => '', 'supplier_id' => '' }, partial: 'settings/myucto'

  project_module :myucto do
    permission :view_myucto, { myucto_projects: [:show] }
    permission :manage_myucto, { myucto_projects: [:show, :update, :retry_events, :attach_invoice, :resume_event] }
  end

  menu :project_menu, :myucto, { controller: 'myucto_projects', action: 'show' },
       caption: :label_myucto, param: :project_id, after: :time_entries
end

Rails.application.config.to_prepare do
  require_dependency 'myucto/time_entry_patch'
  TimeEntry.include Myucto::TimeEntryPatch unless TimeEntry.included_modules.include?(Myucto::TimeEntryPatch)
  require_dependency 'myucto/timelog_controller_patch'
  TimelogController.include Myucto::TimelogControllerPatch unless TimelogController.included_modules.include?(Myucto::TimelogControllerPatch)
end
