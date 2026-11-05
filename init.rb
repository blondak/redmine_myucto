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
    permission :manage_myucto, { myucto_projects: [:show, :update, :retry_events, :attach_invoice, :resume_event, :queue_existing],
                                 projects: [:settings] }
  end

  menu :project_menu, :myucto, { controller: 'myucto_projects', action: 'show' },
       caption: :label_myucto, param: :project_id, after: :time_entries
end

# Redmine 6 loads plugin init.rb from its own to_prepare callback. Registering
# another config.to_prepare here is too late: that block never runs on boot.
# Apply idempotent patches now; Redmine reruns this file on development reload.
# Register on the actual controller helper chains used to render both views.
[ProjectsController, MyuctoProjectsController].each do |controller|
  controller.helper Myucto::ProjectsHelperPatch
end
TimeEntry.include Myucto::TimeEntryPatch unless TimeEntry.included_modules.include?(Myucto::TimeEntryPatch)
TimelogController.include Myucto::TimelogControllerPatch unless TimelogController.included_modules.include?(Myucto::TimelogControllerPatch)

Myucto::BackgroundBoot.install(Rails.application)
