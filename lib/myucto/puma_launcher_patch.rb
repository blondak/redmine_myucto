# frozen_string_literal: true

module Myucto
  module PumaLauncherPatch
    def initialize(...)
      super
      Myucto::BackgroundBoot.configure_puma(config)
    end
  end
end
