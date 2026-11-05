# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/myucto/synchronizer'
require_relative '../../lib/myucto/unavailable'

class SynchronizerTest < Minitest::Test
  class Client
    attr_accessor :report, :invoice_data, :after_save, :before_save
    attr_reader :writes

    def initialize(report)
      @report = report
      @invoice_data = { 'status' => 'draft', 'project_id' => 8 }
      @writes = []
    end

    def invoice(_id)
      copy(invoice_data)
    end

    def work_report(_id)
      copy(report)
    end

    def save_work_report(_id, report)
      before_save&.call(self)
      @writes << copy(report)
      @report = copy(report)
      # MyUcto replaces item IDs and returns DECIMALs as floats.
      @report['items'].each_with_index do |row, index|
        row['id'] = 100 + index
        row['hours'] = row['hours'].to_f
        row['rate'] = row['rate'].to_f
        row['order_index'] ||= index
      end
      after_save&.call(self)
      copy(@report)
    end

    def copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end

  def setup
    @old = row('Original [TE#12]')
    @client = Client.new(report([@old]))
    @service = Myucto::Synchronizer.new(client: @client)
  end

  def row(description, **fields)
    { 'description' => description, 'work_date' => '2026-10-04', 'hours' => 2,
      'rate' => 1500, 'order_index' => 0 }.merge(fields.transform_keys(&:to_s))
  end

  def report(items)
    { 'title' => 'Existing title', 'project_id' => 8, 'vat_rate_id' => 3,
      'materials' => [{ 'description' => 'Cable', 'quantity' => 2 }], 'items' => items }
  end

  def reconcile(desired = row('Updated'), previous: @old)
    @service.reconcile(invoice_id: 42, time_entry_id: 12, desired: desired, previous: previous)
  end

  def test_updates_only_owned_row_and_preserves_manual_rate_metadata_and_other_rows
    manual = row('Manual', hours: '3.5', order_index: 1)
    other = row('Other [TE#123]', order_index: 2)
    @client.report['items'] += [manual, other]
    @client.report['items'][0]['rate'] = '1800.00'
    result = reconcile(row('Updated', hours: 4, rate: 99))
    assert_equal 'Updated [TE#12]', result['description']
    assert_equal 1800, result['rate']
    assert_equal 4, result['hours']
    assert_equal [manual, other], @client.writes.last['items'].drop(1)
    assert_equal 'Existing title', @client.writes.last['title']
    assert_equal 8, @client.writes.last['project_id']
    assert_equal 3, @client.writes.last['vat_rate_id']
    assert_equal [{ 'description' => 'Cable', 'quantity' => 2 }], @client.writes.last['materials']
  end

  def test_creates_missing_report_with_invoice_project_and_custom_title
    @client.report = nil
    result = @service.reconcile(invoice_id: 42, time_entry_id: 12, desired: row('New'), title: 'October')
    assert_equal 'New [TE#12]', result['description']
    assert_equal 'October', @client.report['title']
    assert_equal 8, @client.report['project_id']
  end

  def test_adds_row_without_touching_marker_embedded_in_manual_description
    manual = row('Mention [TE#12] in a sentence')
    @client.report['items'] = [manual]
    reconcile(previous: nil)
    assert_equal manual, @client.writes.last['items'].first
    assert_equal 2, @client.report['items'].size
  end

  def test_repeated_success_is_a_noop_and_returns_current_rate
    @client.report['items'][0]['rate'] = 1800
    result = reconcile(row('Original', rate: 99), previous: nil)
    assert_empty @client.writes
    assert_equal 1800, result['rate']
  end

  def test_accepts_success_after_lost_response
    @client.after_save = ->(_client) { raise Myucto::Unavailable, 'timeout' }
    assert_raises(Myucto::Unavailable) { reconcile }
    @client.after_save = nil
    assert_equal 'Updated [TE#12]', reconcile['description']
    assert_equal 1, @client.writes.size
  end

  def test_delete_last_row_sends_empty_items_and_keeps_report
    assert_nil reconcile(nil)
    assert_equal [], @client.report['items']
    assert_equal 'Existing title', @client.report['title']
    assert_nil reconcile(nil)
    assert_equal 1, @client.writes.size
  end

  def test_missing_previously_synced_marker_is_conflict
    @client.report['items'] = []
    assert_raises(Myucto::Conflict) { reconcile }
    assert_empty @client.writes
  end

  def test_duplicate_markers_are_conflict_even_if_desired_matches
    @client.report['items'] << row('Original [TE#12]')
    assert_raises(Myucto::Conflict) { reconcile(row('Original')) }
    assert_empty @client.writes
  end

  def test_manual_change_of_each_owned_field_is_conflict_for_update_and_delete
    { 'description' => 'Manual edit [TE#12]', 'work_date' => '2026-10-05', 'hours' => 3 }.each do |key, value|
      [nil, row('Updated')].each do |desired|
        @client.report = report([@old.merge(key => value)])
        assert_raises(Myucto::Conflict, key) { reconcile(desired) }
      end
    end
    assert_empty @client.writes
  end

  def test_unknown_existing_marker_is_not_overwritten
    assert_raises(Myucto::Conflict) { reconcile(previous: nil) }
    assert_empty @client.writes
  end

  def test_draft_and_exposed_locks_are_required
    [ { 'status' => 'issued' }, { 'locked' => true },
      { 'locked' => { 'is_locked' => true } },
      { 'locked' => { 'is_locked' => false, 'date_locked' => true } },
      { 'locked' => { 'reasons' => ['posted'] } } ].each do |fields|
      @client.invoice_data = { 'status' => 'draft' }.merge(fields)
      assert_raises(Myucto::Conflict) { reconcile }
    end
    assert_empty @client.writes
  end

  def test_empty_lock_object_is_not_locked
    @client.invoice_data['locked'] = { 'is_locked' => false, 'date_locked' => false, 'reasons' => [] }
    assert_equal 'Updated [TE#12]', reconcile['description']
  end

  def test_postwrite_issue_and_concurrent_manual_changes_are_visible
    @client.after_save = ->(client) { client.invoice_data['status'] = 'issued' }
    assert_raises(Myucto::Conflict) { reconcile }
    setup
    @client.report['items'] << row('Manual', order_index: 1)
    @client.after_save = ->(client) { client.report['items'][1]['hours'] = 99 }
    assert_raises(Myucto::Conflict) { reconcile }
  end

  def test_postwrite_missing_report_is_conflict
    @client.after_save = ->(client) { client.report = nil }
    assert_raises(Myucto::Conflict) { reconcile }
  end

  def test_numeric_strings_and_null_dates_are_normalized
    @client.report['items'][0].merge!('hours' => '2.000', 'rate' => '1500.00', 'work_date' => nil)
    result = reconcile(row('Original', work_date: ''))
    assert_nil result['work_date']
    assert_equal 2.0, result['hours']
    assert_empty @client.writes
  end
end
