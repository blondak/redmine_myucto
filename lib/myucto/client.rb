# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'
require_relative 'unavailable'
require_relative 'conflict'
require_relative 'uncertain_create'

module Myucto
  # MyUcto returns bare objects, except for its paginated list endpoints.
  class Client
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20
    PAGE_SIZE = 200

    def initialize(config = Myucto.configuration, discovery: false)
      @config = config.transform_keys(&:to_s)
      @base_uri = URI.parse(@config.fetch('base_url', '').to_s.sub(%r{/+\z}, ''))
      unless %w[http https].include?(@base_uri.scheme) && @base_uri.host &&
             !@base_uri.userinfo && !@base_uri.query && !@base_uri.fragment
        raise Error, 'MyUcto base URL must be an HTTP(S) URL without credentials, query or fragment.'
      end
      @token = @config['api_token'].to_s
      @token = ENV.fetch('MYUCTO_API_TOKEN', '') if @token.empty?
      raise Error, 'MYUCTO_API_TOKEN is not configured.' if @token.empty?
      raise Error, 'MyUcto token contains invalid characters.' if @token.match?(/[\r\n]/)
      @discovery = discovery
      @supplier_id = discovery ? nil : positive_id(@config['supplier_id'])
    rescue URI::InvalidURIError
      raise Error, 'MyUcto base URL is invalid.'
    end

    # Discovery works before a supplier has been selected. MyÚčto restricts this
    # list to the token's company/memberships; no guessed supplier header is sent.
    def supplier_choices
      identity = test_connection
      unless identity.dig('token', 'scope') == 'read_write'
        raise Conflict, 'MyUcto token must have read_write access.'
      end
      rows = request(:get, 'suppliers')
      unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) }
        raise Unavailable, 'MyUcto returned an invalid supplier list.'
      end
      suppliers = rows.map do |row|
        id = positive_id(row['id'])
        company = row['company_name'].to_s
        display = row['display_name'].to_s
        name = company.empty? ? display : company
        { 'id' => id, 'name' => name, 'display_name' => display,
          'ic' => row['ic'].to_s, 'dic' => row['dic'].to_s,
          'text' => "#{name} (ID #{id})" }
      end
      { 'suppliers' => suppliers, 'current_supplier_id' => identity.dig('supplier', 'id') }
    end

    def clients
      records = []
      page = 1
      loop do
        result = request(:get, 'clients', query: { page: page, per_page: PAGE_SIZE, role: 'customers' })
        unless result.is_a?(Hash) && result['data'].is_a?(Array) && result['meta'].is_a?(Hash)
          raise Unavailable, 'MyUcto returned an invalid client list.'
        end
        records.concat(result['data'])
        pages = Integer(result['meta']['pages'])
        break if page >= pages
        raise Unavailable, 'MyUcto returned inconsistent pagination.' if result['data'].empty?
        page += 1
      end
      records
    rescue ArgumentError, TypeError
      raise Unavailable, 'MyUcto returned invalid pagination.'
    end

    def invoice(id)
      object_response(request(:get, "invoices/#{positive_id(id)}"))
    end

    def work_report(id)
      result = request(:get, "invoices/#{positive_id(id)}/work-report")
      result.nil? ? nil : object_response(result)
    end

    def billing_templates
      rows = request(:get, 'work-report-billing-templates')
      unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row['id'].to_s.match?(/\A[1-9]\d*\z/) && row['currency'].to_s.match?(/\A[A-Z]{3}\z/) && row['bands'].is_a?(Array) }
        raise Unavailable, 'MyUcto returned an invalid billing template list.'
      end
      rows
    end

    def create_invoice(client_id:, period:, project_name:, currency: nil)
      payload = {
        client_id: positive_id(client_id), invoice_type: 'invoice', items: [],
        note_above_items: "Redmine: #{project_name} / #{period}"
      }
      payload[:currency] = currency if currency
      result = request(:post, 'invoices', body: payload)
      unless result.is_a?(Hash) && result['id'].to_s.match?(/\A[1-9]\d*\z/)
        raise UncertainCreate, 'MyUcto may have created the draft but returned no usable invoice ID. Check MyUcto before retrying.'
      end
      result
    end

    def save_work_report(id, report)
      object_response(request(:put, "invoices/#{positive_id(id)}/work-report", body: report))
    end

    def verify_connection!
      result = test_connection
      unless result.dig('supplier', 'id').to_s == @supplier_id.to_s && result.dig('token', 'scope') == 'read_write'
        raise Conflict, 'MyUcto token must have read_write access to the configured supplier.'
      end
      true
    end

    def test_connection
      object_response(request(:get, 'auth/api-me'))
    end

    private

    def positive_id(value)
      raise Error, 'MyUcto IDs must be positive integers.' unless value.to_s.match?(/\A[1-9]\d*\z/)
      value.to_i
    end

    def object_response(result)
      raise Unavailable, 'MyUcto returned an invalid object.' unless result.is_a?(Hash)
      result
    end

    def request(method, path, query: nil, body: nil)
      if @discovery && !%w[auth/api-me suppliers].include?(path)
        raise Error, 'Select a supplier before using business endpoints.'
      end
      uri = @base_uri.dup
      prefix = uri.path.sub(%r{/+\z}, '')
      prefix += '/api/v1' unless prefix.end_with?('/api/v1')
      uri.path = "#{prefix}/#{path}"
      uri.query = URI.encode_www_form(query) if query
      klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.fetch(method)
      outgoing = klass.new(uri.request_uri)
      outgoing['Authorization'] = "Bearer #{@token}"
      outgoing['X-Supplier-Id'] = @supplier_id.to_s if @supplier_id
      outgoing['Accept'] = 'application/json'
      if body
        outgoing['Content-Type'] = 'application/json'
        outgoing.body = JSON.generate(body)
      end

      # Do not follow redirects or retry requests; a failed create may have committed.
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = READ_TIMEOUT if http.respond_to?(:write_timeout=)
      http.max_retries = 0
      response = http.start { |connection| connection.request(outgoing) }
      status = response.code.to_i
      if method == :post && (status >= 500 || status.between?(300, 399) || status == 408)
        raise UncertainCreate, 'MyUcto may have created the draft. Check MyUcto before retrying.'
      end
      raise Conflict, 'MyUcto rejected the change because the document is locked or no longer a draft.' if status == 409
      unless status.between?(200, 299)
        raise Unavailable, "MyUcto API request failed (HTTP #{status})."
      end
      JSON.parse(response.body)
    rescue JSON::ParserError, TypeError
      if method == :post
        raise UncertainCreate, 'MyUcto may have created the draft but returned an invalid response. Check MyUcto before retrying.'
      end
      raise Unavailable, 'MyUcto returned invalid JSON.'
    rescue Timeout::Error, SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError,
           Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError
      if method == :post
        raise UncertainCreate, 'The MyUcto create request was interrupted. Check MyUcto for a draft before retrying.'
      end
      raise Unavailable, 'MyUcto could not be reached. Try again later.'
    end
  end
end
