# frozen_string_literal: true
require 'minitest/autorun'
require 'open3'
require 'rbconfig'

class ProjectsHelperPatchTest < Minitest::Test
  def test_settings_tab_requires_management_permission_and_enabled_module
    # Isolated process avoids replacing Redmine's User/Project classes in the
    # database tests. Redmine itself supplies allowed_to? and module_enabled?.
    script = <<~'SCRIPT'
      require ARGV.fetch(0)
      class User
        def self.current; @current; end
        def self.current=(value); @current = value; end
      end
      Actor = Struct.new(:can_manage) do
        def allowed_to?(permission, _project)
          permission == :manage_myucto && can_manage
        end
      end
      Project = Struct.new(:enabled) do
        def module_enabled?(name); name == :myucto && enabled; end
      end
      Base = Module.new do
        def project_settings_tabs; [{ name: 'info' }]; end
      end
      View = Class.new do
        include Base
        prepend Myucto::ProjectsHelperPatch
        def initialize(project); @project = project; end
      end
      [true, false].product([true, false]).each do |enabled, manage|
        User.current = Actor.new(manage)
        view = View.new(Project.new(enabled))
        tabs = view.project_settings_tabs
        expected = enabled && manage
        raise 'incorrect tab permission' unless tabs.any? { |tab| tab[:name] == 'myucto' } == expected
        raise 'core tab lost' unless tabs.first[:name] == 'info'
        raise 'duplicate tab' unless view.project_settings_tabs.count { |tab| tab[:name] == 'myucto' } == (expected ? 1 : 0)
        # An unauthorized partial render must not touch models or the API.
        raise 'settings data leaked' if !expected && view.myucto_settings_data
      end
    SCRIPT
    output, status = Open3.capture2e(RbConfig.ruby, '-e', script,
                                    File.expand_path('../../lib/myucto/projects_helper_patch.rb', __dir__))
    assert status.success?, output
  end
end
