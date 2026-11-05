# frozen_string_literal: true

module Myucto
  module BackgroundBoot
    def self.install(application)
      return if application.instance_variable_defined?(:@myucto_background_boot_installed)
      application.instance_variable_set(:@myucto_background_boot_installed, true)
      application.singleton_class.prepend(ApplicationPatch)

      application.reloader.before_class_unload do
        # Never wait for a job blocked on the reloader while holding its unload
        # lock. Do this before Zeitwerk removes any explicitly required children
        # of Myucto; their individual on_unload callbacks need not be tracked.
        Myucto::Background.stop!(wait: false)
      end

      # Redmine loads init.rb inside to_prepare, before Rails' after_initialize.
      # Register once; development reloads must not multiply poll chains.
      application.config.after_initialize do
        Myucto::BackgroundBoot.start_server
      end
    end

    def self.start_server
      if defined?(Puma)
        # `rails server` loads Rails before Puma constructs its Launcher, while
        # `puma` preloads Rails from inside an existing Launcher. Cover both.
        require 'puma/launcher'
        Puma::Launcher.prepend(PumaLauncherPatch) unless Puma::Launcher < PumaLauncherPatch
        configure_puma(Puma.cli_config) if Puma.respond_to?(:cli_config) && Puma.cli_config
      elsif defined?(Rails::Server)
        Background.start!
      end
    end

    def self.configure_puma(config)
      return if config.instance_variable_defined?(:@myucto_hooks_installed)
      config.instance_variable_set(:@myucto_hooks_installed, true)
      if config.options[:workers].to_i.positive?
        config.configure do |dsl|
          dsl.on_worker_boot { Myucto::Background.start! }
          dsl.on_worker_shutdown { Myucto::Background.stop! }
        end
      else
        Background.start!
      end
    end
  end
end
