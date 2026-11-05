# Run only in a disposable Redmine database, through `rails runner`.
# Unlike the standalone unit tests, this exercises Redmine's real helper chain,
# access control, project modules and plugin migrations.
raise 'Refusing to modify a database without MYUCTO_DISPOSABLE_TEST=1' unless ENV['MYUCTO_DISPOSABLE_TEST'] == '1'

raise 'TimeEntry callbacks were not installed' unless TimeEntry.ancestors.include?(Myucto::TimeEntryPatch)
raise 'Timelog error reporting was not installed' unless TimelogController.ancestors.include?(Myucto::TimelogControllerPatch)
puts 'PASS model and controller patches installed'

project = Project.create!(name: 'Myucto settings smoke', identifier: "myucto-smoke-#{SecureRandom.hex(4)}",
                          enabled_module_names: ['myucto'])
admin = User.where(admin: true).first!
User.current = admin

require 'action_dispatch/testing/test_request'
settings_view = -> {
  controller = ProjectsController.new
  controller.set_request!(ActionDispatch::TestRequest.create)
  controller.set_response!(ActionDispatch::Response.new)
  view = controller.view_context
  view.instance_variable_set(:@project, project)
  view
}
assert_tab = ->(expected, label) {
  actual = settings_view.call.project_settings_tabs.count { |tab| tab[:name] == 'myucto' }
  raise "#{label}: expected #{expected} MyÚčto tabs, got #{actual}" unless actual == expected
  puts "PASS #{label}"
}

assert_tab.call(1, 'administrator sees settings')

MyuctoProjectSetting.create!(project: project, client_id: 7, allowed_user_ids: [admin.id])
view = settings_view.call
view.instance_variable_set(:@clients, [{ 'id' => 7, 'company_name' => 'Synthetic client' }])
html = view.render(partial: 'myucto_projects/settings')
%w[myucto_project_setting[client_id] myucto_project_setting[allowed_user_ids][]].each do |field|
  raise "Missing form field #{field}" unless html.include?(field)
end
raise 'Customer label missing' unless html.include?('Synthetic client')
puts 'PASS native settings form renders customer and allowed users'

setting = MyuctoProjectSetting.find_by!(project: project)
setting.update!(enabled: true)
activity = TimeEntryActivity.create!(name: "Synthetic activity #{project.id}", active: true)
time_entry = TimeEntry.create!(project: project, user: admin, author: admin,
                              activity: activity, hours: 1, spent_on: Date.current,
                              comments: 'Synthetic callback check')
event = MyuctoSyncEvent.find_by!(time_entry_id: time_entry.id)
raise 'Incorrect queued owner' unless event.payload_data['user_id'] == admin.id
puts 'PASS real Redmine TimeEntry create enqueues synchronization'

viewer_role = Role.create!(name: "Myucto viewer #{project.id}", permissions: [:view_myucto])
manager_role = Role.create!(name: "Myucto manager #{project.id}", permissions: [:manage_myucto])
user = User.create!(login: "myucto-smoke-#{project.id}", firstname: 'Synthetic', lastname: 'User',
                    mail: "myucto-smoke-#{project.id}@example.test", password: 'test-only-password-123!',
                    password_confirmation: 'test-only-password-123!')
member = Member.create!(project: project, principal: user, roles: [viewer_role])
User.current = User.find(user.id)
assert_tab.call(0, 'view-only role cannot configure')
raise 'Settings data leaked to viewer' unless settings_view.call.myucto_settings_data.nil?

member.roles = [manager_role]
member.save!
User.current = User.find(user.id)
assert_tab.call(1, 'manager sees settings without edit_project')
raise 'Manager cannot access project settings' unless User.current.allowed_to?({ controller: 'projects', action: 'settings' }, project)

User.current = admin
project.enabled_module_names = []
project.save!
assert_tab.call(0, 'disabled module hides settings even from administrator')
puts "PASS Redmine #{Redmine::VERSION} / Ruby #{RUBY_VERSION}"
