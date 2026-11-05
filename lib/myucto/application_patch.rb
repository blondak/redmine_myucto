# frozen_string_literal: true

module Myucto
  module ApplicationPatch
    def call(env)
      # Covers Rack servers and PID changes after preload/fork. Merely loading
      # the Rails environment from rake/runner never starts a background worker.
      Myucto::Background.start!
      super
    end
  end
end
