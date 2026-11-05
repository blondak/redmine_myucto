# frozen_string_literal: true

# Isolated Zeitwerk lifecycle test using the gems of the real Redmine image.
# Does not boot/reload Redmine core and does not touch its database.
require 'active_job'
require 'zeitwerk'
require 'logger'

loader = Zeitwerk::Loader.new
loader.push_dir(File.expand_path('../../lib', __dir__))
loader.push_dir(File.expand_path('../../app/jobs', __dir__))
loader.enable_reloading
loader.setup

module Rails
  class << self
    attr_accessor :logger
  end
end
Rails.logger = Logger.new(File::NULL)
config = Object.new
def config.after_initialize(&block); end
reloader = Object.new
reloader.define_singleton_method(:before_class_unload) { |&block| @cleanup = block }
reloader.define_singleton_method(:unload!) { @cleanup.call }
application = Object.new
application.define_singleton_method(:config) { config }
application.define_singleton_method(:reloader) { reloader }

Myucto::BackgroundBoot.install(application)
Myucto::Background.define_singleton_method(:build_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
Myucto::Background.start!
old_background = Myucto::Background
old_runtime = old_background.instance_variable_get(:@instance)
old_watchdog = old_runtime.instance_variable_get(:@watchdog)
old_adapter = MyuctoSyncJob.queue_adapter
before = application.singleton_class.ancestors.count { |mod| mod.name == 'Myucto::ApplicationPatch' }

reloader.unload!
loader.reload
Myucto::BackgroundBoot.install(application)

raise 'Background was not reloaded' if Myucto::Background.equal?(old_background)
raise 'Old dispatcher was retained' if old_background.instance_variable_get(:@instance)
raise 'Old watchdog is still running' if old_watchdog.running?
after = application.singleton_class.ancestors.count { |mod| mod.name == 'Myucto::ApplicationPatch' }
raise 'Application patches accumulated' unless before == after && after == 1
puts 'PASS Zeitwerk reload stops old dispatcher/watchdog without duplicating application patches'

Myucto::Background.define_singleton_method(:build_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
Myucto::Background.start!
current = Myucto::Background.instance_variable_get(:@instance)
raise 'Dispatcher was reused' if current.equal?(old_runtime)
raise 'Adapter was reused' if MyuctoSyncJob.queue_adapter.equal?(old_adapter)
Myucto::Background.start!
raise 'Second dispatcher created' unless Myucto::Background.instance_variable_get(:@instance).equal?(current)
Myucto::Background.stop!
puts 'PASS reloaded plugin starts exactly one new dispatcher with its own adapter'
