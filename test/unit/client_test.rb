# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require_relative '../../lib/myucto/client'

class MyuctoClientTest < Minitest::Test
  Response = Struct.new(:code, :body)

  class Transport
    attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def use_ssl?
      use_ssl
    end

    def start
      yield self
    end

    def request(outgoing)
      @requests << outgoing
      response = @responses.shift
      raise response if response.is_a?(Exception)
      raise 'Unexpected extra request' unless response
      response
    end
  end

  def setup
    @config = { 'base_url' => 'https://billing.example.test', 'supplier_id' => '7', 'api_token' => 'synthetic-token' }
  end

  def response(value, status = 200)
    Response.new(status.to_s, JSON.generate(value))
  end

  def with_transport(*responses)
    transport = Transport.new(*responses)
    Net::HTTP.stub(:new, transport) { yield Myucto::Client.new(@config), transport }
  end


  def test_billing_templates_and_currency_are_supplier_scoped
    template = { 'id' => 12, 'name' => 'Support', 'currency' => 'EUR', 'bands' => [] }
    with_transport(response([template]), response({ 'id' => 50 })) do |client, transport|
      assert_equal [template], client.billing_templates
      assert_equal '/api/v1/work-report-billing-templates', transport.requests.first.path
      assert_equal '7', transport.requests.first['X-Supplier-Id']
      client.create_invoice(client_id: 8, period: '2026-10', project_name: 'Example', currency: 'EUR')
      assert_equal 'EUR', JSON.parse(transport.requests.last.body)['currency']
    end
  end

  def test_invalid_billing_template_response_is_rejected
    [nil, {}, [{ 'id' => 12 }]].each do |body|
      with_transport(response(body)) { |client, _| assert_raises(Myucto::Unavailable) { client.billing_templates } }
    end
  end

  def test_create_redirects_and_http_timeout_are_ambiguous
    [302, 307, 408].each do |status|
      with_transport(response({}, status)) do |client, transport|
        assert_raises(Myucto::UncertainCreate) do
          client.create_invoice(client_id: 8, period: '2026-10', project_name: 'Example')
        end
        assert_equal 1, transport.requests.size
      end
    end
  end

  def test_discovery_without_supplier_id_returns_names_and_identity_without_scope_header
    @config.delete('supplier_id')
    rows = [{ 'id' => 3, 'company_name' => 'Example s.r.o.', 'display_name' => 'Example', 'ic' => '12345678', 'dic' => 'CZ12345678' }]
    transport = Transport.new(response({ 'supplier' => { 'id' => 3 }, 'token' => { 'scope' => 'read_write' } }), response(rows))
    Net::HTTP.stub(:new, transport) do
      result = Myucto::Client.new(@config, discovery: true).supplier_choices
      assert_equal 3, result['current_supplier_id']
      assert_equal 'Example s.r.o. (ID 3)', result['suppliers'][0]['text']
      assert_equal '12345678', result['suppliers'][0]['ic']
      assert_equal ['/api/v1/auth/api-me', '/api/v1/suppliers'], transport.requests.map(&:path)
      transport.requests.each { |request| assert_nil request['X-Supplier-Id'] }
      refute result.to_s.include?('synthetic-token')
    end
  end

  def test_discovery_cannot_access_business_endpoints
    client = Myucto::Client.new(@config, discovery: true)
    assert_raises(Myucto::Error) { client.invoice(10) }
    assert_raises(Myucto::Error) { client.create_invoice(client_id: 1, period: '2026-11', project_name: 'Example') }
  end

  def test_normal_client_still_requires_supplier_id
    @config.delete('supplier_id')
    assert_raises(Myucto::Error) { Myucto::Client.new(@config) }
  end

  def test_discovery_rejects_read_only_token_before_loading_suppliers
    transport = Transport.new(response({ 'token' => { 'scope' => 'read' } }))
    Net::HTTP.stub(:new, transport) do
      assert_raises(Myucto::Conflict) { Myucto::Client.new(@config, discovery: true).supplier_choices }
      assert_equal 1, transport.requests.size
    end
  end

  def test_discovery_handles_empty_and_malformed_supplier_lists
    [[], {}].each do |rows|
      transport = Transport.new(response({ 'token' => { 'scope' => 'read_write' } }), response(rows))
      Net::HTTP.stub(:new, transport) do
        client = Myucto::Client.new(@config, discovery: true)
        if rows.is_a?(Array)
          assert_equal [], client.supplier_choices['suppliers']
        else
          assert_raises(Myucto::Unavailable) { client.supplier_choices }
        end
      end
    end
  end

  def test_clients_fetches_every_page_and_sets_authentication_and_timeouts
    with_transport(response({ 'data' => [{ 'id' => 1 }], 'meta' => { 'pages' => 2 } }),
                   response({ 'data' => [{ 'id' => 2 }], 'meta' => { 'pages' => 2 } })) do |client, transport|
      assert_equal [{ 'id' => 1 }, { 'id' => 2 }], client.clients
      assert_equal ['/api/v1/clients?page=1&per_page=200&role=customers', '/api/v1/clients?page=2&per_page=200&role=customers'], transport.requests.map(&:path)
      assert_equal 'Bearer synthetic-token', transport.requests.first['Authorization']
      assert_equal '7', transport.requests.first['X-Supplier-Id']
      assert transport.use_ssl
      assert_equal OpenSSL::SSL::VERIFY_PEER, transport.verify_mode
      assert_operator transport.open_timeout, :>, 0
      assert_operator transport.read_timeout, :>, 0
      assert_equal 0, transport.max_retries
    end
  end

  def test_bare_invoice_and_nullable_report
    with_transport(response({ 'id' => 12, 'status' => 'draft' }), response(nil)) do |client, _|
      assert_equal 'draft', client.invoice(12)['status']
      assert_nil client.work_report(12)
    end
  end

  def test_base_url_accepts_an_installation_path_and_api_prefix
    @config['base_url'] = 'https://billing.example.test/accounting/api/v1/'
    with_transport(response({ 'user' => {}, 'supplier' => { 'id' => 7 } })) do |client, transport|
      assert_equal 7, client.test_connection['supplier']['id']
      assert_equal '/accounting/api/v1/auth/api-me', transport.requests.first.path
    end
  end

  def test_verifies_token_write_scope_and_effective_supplier
    identity = { 'supplier' => { 'id' => 7 }, 'token' => { 'scope' => 'read_write' } }
    with_transport(response(identity)) do |client, _|
      assert_equal true, client.verify_connection!
    end
    [identity.merge('supplier' => { 'id' => 99 }),
     identity.merge('token' => { 'scope' => 'read' }),
     identity.merge('token' => nil),
     identity.merge('supplier' => nil)].each do |invalid|
      with_transport(response(invalid)) do |client, transport|
        assert_raises(Myucto::Conflict) { client.verify_connection! }
        assert_equal 1, transport.requests.size
        assert_instance_of Net::HTTP::Get, transport.requests.first
      end
    end
  end

  def test_creation_sends_an_empty_draft_and_preserves_server_defaults
    with_transport(response({ 'id' => 23, 'status' => 'draft', 'items' => [] }, 201)) do |client, transport|
      assert_equal 23, client.create_invoice(client_id: 8, period: '2026-10', project_name: 'Example')['id']
      outgoing = transport.requests.fetch(0)
      assert_instance_of Net::HTTP::Post, outgoing
      assert_equal '/api/v1/invoices', outgoing.path
      assert_equal({ 'client_id' => 8, 'invoice_type' => 'invoice', 'items' => [],
                     'note_above_items' => 'Redmine: Example / 2026-10' }, JSON.parse(outgoing.body))
    end
  end

  def test_saving_report_allows_empty_items_without_changing_invoice_lines
    report = { 'title' => 'Example / 2026-10', 'items' => [] }
    with_transport(response(report.merge('id' => 30))) do |client, transport|
      assert_equal 30, client.save_work_report(23, report)['id']
      outgoing = transport.requests.fetch(0)
      assert_instance_of Net::HTTP::Put, outgoing
      assert_equal '/api/v1/invoices/23/work-report', outgoing.path
      assert_equal report, JSON.parse(outgoing.body)
    end
  end

  def test_conflict_when_server_has_locked_or_issued_invoice
    with_transport(response({ 'error' => { 'code' => 'not_editable' } }, 409)) do |client, _|
      assert_raises(Myucto::Conflict) { client.save_work_report(23, { 'title' => 'Example', 'items' => [] }) }
    end
  end

  def test_failed_reads_are_unavailable
    [Net::ReadTimeout.new, response({}, 503), Response.new('200', 'not JSON')].each do |failure|
      with_transport(failure) do |client, transport|
        assert_raises(Myucto::Unavailable) { client.invoice(23) }
        assert_equal 1, transport.requests.length
      end
    end
  end

  def test_create_interruptions_and_ambiguous_responses_never_retry
    [Net::ReadTimeout.new, EOFError.new, response({}, 500), Response.new('201', 'not JSON'), response({})].each do |failure|
      with_transport(failure) do |client, transport|
        assert_raises(Myucto::UncertainCreate) do
          client.create_invoice(client_id: 8, period: '2026-10', project_name: 'Example')
        end
        assert_equal 1, transport.requests.length
      end
    end
  end

  def test_explicit_create_rejection_is_not_ambiguous
    with_transport(response({ 'error' => { 'code' => 'validation_failed' } }, 400)) do |client, transport|
      assert_raises(Myucto::Unavailable) { client.create_invoice(client_id: 8, period: '2026-10', project_name: 'Example') }
      assert_equal 1, transport.requests.length
    end
  end

  def test_redirects_are_rejected_without_sending_another_request
    with_transport(Response.new('302', '')) do |client, transport|
      assert_raises(Myucto::Unavailable) { client.test_connection }
      assert_equal 1, transport.requests.length
    end
  end

  def test_rejects_invalid_ids_and_urls_before_sending_credentials
    ['23/issue', 0, -1, ''].each do |id|
      with_transport do |client, transport|
        assert_raises(Myucto::Error) { client.invoice(id) }
        assert_empty transport.requests
      end
    end
    ['https://user:secret@example.test', 'file:///etc/passwd', 'https://example.test/?token=secret'].each do |url|
      @config['base_url'] = url
      assert_raises(Myucto::Error) { Myucto::Client.new(@config) }
    end
  end

  def test_invalid_pagination_fails_without_spinning
    with_transport(response({ 'data' => [], 'meta' => { 'pages' => 2 } })) do |client, transport|
      assert_raises(Myucto::Unavailable) { client.clients }
      assert_equal 1, transport.requests.length
    end
  end
end
