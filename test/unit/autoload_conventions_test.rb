# frozen_string_literal: true
require 'minitest/autorun'
require 'open3'
require 'rbconfig'

class AutoloadConventionsTest < Minitest::Test
  def test_every_library_file_defines_its_expected_constant_in_a_fresh_process
    # Redmine eagerly loads plugin lib directories. Explicit requires must not
    # hide files that violate Zeitwerk's file-path-to-constant contract.
    root = File.expand_path('../../lib', __dir__)
    script = <<~'SCRIPT'
      root = ARGV.fetch(0)
      require File.join(root, 'myucto')
      Dir[File.join(root, '**', '*.rb')].sort.each do |file|
        require file
        parts = file.delete_prefix("#{root}/").delete_suffix('.rb').split('/')
        parts.reduce(Object) do |parent, part|
          name = part.split('_').map(&:capitalize).join
          parent.const_get(name, false)
        end
      end
    SCRIPT
    output, status = Open3.capture2e(RbConfig.ruby, '-e', script, root)
    assert status.success?, output
  end
end
