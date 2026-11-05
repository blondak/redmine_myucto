# frozen_string_literal: true
require 'digest'
require_relative 'myucto/errors'
require_relative 'myucto/client'
require_relative 'myucto/synchronizer'
require_relative 'myucto/worker'

module Myucto
  def self.configuration
    Setting.plugin_redmine_myucto.to_h.merge('api_token' => ENV.fetch('MYUCTO_API_TOKEN', ''))
  end

  def self.connection_key
    config = configuration
    base = config['base_url'].to_s.sub(%r{/+\z}, '').sub(%r{/api/v1\z}, '')
    Digest::SHA256.hexdigest("#{base}|#{config['supplier_id']}")
  end

  def self.assert_connection!(binding)
    if binding.connection_key.present? && binding.connection_key != connection_key
      raise Conflict, 'MyÚčto connection changed; restore the original URL and supplier before synchronizing existing bindings.'
    end
  end

  def self.assert_editable!(invoice, id)
    lock = invoice['locked']
    locked = lock == true || (lock.is_a?(Hash) && lock['is_locked'])
    return if invoice['status'] == 'draft' && !locked
    raise Conflict, I18n.t(:myucto_invoice_not_editable, id: id, status: invoice['status'])
  end
end
