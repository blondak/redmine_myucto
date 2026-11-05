# frozen_string_literal: true

require 'bigdecimal'
require 'date'
require_relative 'errors'

module Myucto
  # The caller serializes reconciliation per invoice. MyUcto has no conditional
  # work-report PUT, so simultaneous edits outside the plugin remain a conflict risk.
  class Synchronizer
    OWNED_FIELDS = %w[description work_date hours].freeze
    LOCK_FLAGS = %w[is_locked date_locked accountant_managed].freeze

    def initialize(client:)
      @client = client
    end

    # desired contains description (without marker), work_date, hours and rate.
    # previous is the row returned by the last successful reconciliation.
    # A current remote rate always wins over desired/previous rates.
    def reconcile(invoice_id:, time_entry_id:, desired:, previous: nil, title: 'Výkaz práce')
      id = Integer(time_entry_id)
      raise ArgumentError, 'time_entry_id must be positive' unless id.positive?

      marker = "[TE##{id}]"
      invoice = editable_invoice!(invoice_id)
      report = @client.work_report(invoice_id)
      report ||= { 'title' => title, 'project_id' => invoice['project_id'], 'items' => [] }
      validate_report!(report)
      rows = report.fetch('items')
      matching = rows.each_index.select { |index| rows[index]['description'].to_s.end_with?(marker) }
      raise Conflict, "Duplicate marker #{marker}" if matching.length > 1

      index = matching.first
      current = index.nil? ? nil : normalize(rows[index])
      target = desired && desired_row(desired, marker)
      target['rate'] = current['rate'] if current && target

      # A previous PUT may have succeeded even when its response was lost.
      return current if current && target && owned_equal?(current, target)
      return nil if current.nil? && target.nil?

      if current
        unless previous && owned_equal?(current, normalize(previous))
          raise Conflict, "Work-report row #{marker} was changed outside Redmine"
        end
      elsif previous
        raise Conflict, "Previously synchronized marker #{marker} is missing"
      end

      payload = deep_copy(report)
      if target && current
        payload['items'][index] = payload['items'][index].merge(target)
      elsif target
        target['order_index'] = rows.map { |row| row.fetch('order_index', 0).to_i }.max.to_i + 1
        payload['items'] << target
      else
        payload['items'].delete_at(index)
      end

      editable_invoice!(invoice_id)
      @client.save_work_report(invoice_id, payload)
      editable_invoice!(invoice_id)
      actual = @client.work_report(invoice_id)
      validate_report!(actual)
      unless comparable_report(actual) == comparable_report(payload)
        raise Conflict, "Work report changed while synchronizing #{marker}"
      end
      result = actual['items'].find { |row| row['description'].to_s.end_with?(marker) }
      result && normalize(result)
    end

    private

    def editable_invoice!(id)
      invoice = @client.invoice(id)
      raise Conflict, 'Invoice no longer exists' unless invoice.is_a?(Hash)
      raise Conflict, 'Invoice is no longer a draft' unless invoice['status'] == 'draft'

      lock = invoice['locked']
      locked = if lock.is_a?(Hash)
                 LOCK_FLAGS.any? { |key| truthy?(lock[key]) } || Array(lock['reasons']).any?
               else
                 truthy?(lock)
               end
      raise Conflict, 'Invoice is locked' if locked || truthy?(invoice['is_locked'])

      invoice
    end

    def truthy?(value)
      value == true || value == 1 || value == '1' || value == 'true'
    end

    def validate_report!(report)
      return if report.is_a?(Hash) && report['items'].is_a?(Array) && report['items'].all? { |row| row.is_a?(Hash) }

      raise Conflict, 'Work report is missing or malformed'
    end

    def desired_row(row, marker)
      description = row.fetch('description').to_s.strip
      description = "#{description} #{marker}".strip unless description.end_with?(marker)
      result = normalize(row.merge('description' => description))
      raise ArgumentError, 'hours must be positive' unless decimal(result['hours']).positive?
      raise ArgumentError, 'rate must not be negative' if decimal(result['rate']).negative?
      date = result['work_date']
      if date && (!date.match?(/\A\d{4}-\d{2}-\d{2}\z/) || Date.iso8601(date).iso8601 != date)
        raise ArgumentError, 'work_date must be an ISO date'
      end
      result
    end

    def normalize(row)
      {
        'description' => row.fetch('description').to_s,
        'work_date' => row['work_date'].to_s.empty? ? nil : row['work_date'].to_s,
        'hours' => decimal(row.fetch('hours')).to_f,
        'rate' => decimal(row.fetch('rate')).to_f
      }
    end

    def decimal(value)
      number = BigDecimal(value.to_s)
      raise ArgumentError, 'Non-finite numeric value' unless number.finite?

      number
    end

    def owned_equal?(left, right)
      OWNED_FIELDS.all? { |key| left[key] == right[key] }
    end

    def comparable_report(report)
      items = report['items'].each_with_index.map do |row, index|
        normalize(row).merge('order_index' => row.fetch('order_index', index).to_i)
      end.sort_by { |row| row['order_index'] }
      [report['title'], report['project_id']&.to_s, report['vat_rate_id']&.to_s, items]
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
