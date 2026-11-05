class MyuctoProjectsController < ApplicationController
  helper :projects
  menu_item :settings, only: :update
  before_action :find_myucto_project, except: [:test_connection, :suppliers]
  before_action :authorize, except: [:test_connection, :suppliers]
  before_action :require_admin, only: [:attach_invoice, :resume_event, :test_connection, :suppliers, :queue_existing]

  def show
    load_status
  end

  def update
    @myucto_setting = MyuctoProjectSetting.find_or_initialize_by(project_id: @project.id)
    permitted = params.require(:myucto_project_setting).permit(:enabled, :client_id, allowed_user_ids: [])
    previous_users = @myucto_setting.allowed_user_ids
    @myucto_setting.assign_attributes(permitted)
    allowed = @project.users.pluck(:id) | previous_users
    unless (@myucto_setting.allowed_user_ids - allowed).empty?
      @myucto_setting.errors.add(:allowed_user_ids, l(:error_myucto_invalid_users))
      load_clients
      return render :edit, status: :unprocessable_entity
    end
    candidate = permitted[:client_id].presence
    if candidate
      load_clients
      unless @clients.any? { |client| client_value(client, 'id').to_s == candidate.to_s }
        @myucto_setting.errors.add(:client_id, l(:error_myucto_client_unavailable))
        return render :edit, status: :unprocessable_entity
      end
    end
    if @myucto_setting.save
      flash[:notice] = l(:notice_successful_update)
      redirect_to settings_project_path(@project, tab: 'myucto')
    else
      load_clients
      render :edit, status: :unprocessable_entity
    end
  end

  def queue_existing
    time_entry = @project.time_entries.find(params.require(:time_entry_id))
    if time_entry.myucto_queue_existing!
      flash[:notice] = l(:notice_myucto_existing_queued, id: time_entry.id)
    else
      flash[:notice] = l(:notice_myucto_existing_tracked, id: time_entry.id)
    end
    redirect_to project_myucto_path(@project)
  rescue Myucto::Error => e
    flash[:error] = e.message
    redirect_to project_myucto_path(@project)
  end

  def retry_events
    # Never recreate an invoice whose remote creation may already have succeeded.
    MyuctoInvoiceBinding.transaction do
      bindings = MyuctoInvoiceBinding.where(project_id: @project.id).lock.to_a
      if bindings.any? { |binding| !binding.automatic_retry_safe? }
        flash[:error] = l(:error_myucto_unsafe_retry)
      else
        project_events.where(state: 'failed').update_all(state: 'pending', available_at: Time.current,
                                                       last_error: nil, updated_at: Time.current)
        flash[:notice] = l(:notice_myucto_retry_queued)
      end
    end
    Myucto::Background.wake!
    redirect_to project_myucto_path(@project)
  end

  def attach_invoice
    unless params[:confirm_recovery] == '1' && params[:worker_stopped] == '1'
      flash[:error] = l(:error_myucto_confirmation_required)
      return redirect_to project_myucto_path(@project)
    end
    binding = MyuctoInvoiceBinding.where(project_id: @project.id).find(params[:id])
    invoice_id = params[:invoice_id].to_s
    raise Myucto::Conflict, l(:error_myucto_invoice_id) unless invoice_id.match?(/\A[1-9]\d*\z/)
    binding.with_lock do
      unless %w[uncertain creating].include?(binding.state)
        raise Myucto::Conflict, l(:error_myucto_recovery_state)
      end
      if binding.connection_key.present? && binding.connection_key != Myucto.connection_key
        raise Myucto::Conflict, l(:error_myucto_connection_changed)
      end
      invoice = Myucto::Client.new.invoice(invoice_id)
      unless invoice['id'].to_s == invoice_id && invoice['client_id'].to_s == binding.client_id.to_s
        raise Myucto::Conflict, l(:error_myucto_invoice_mismatch)
      end
      Myucto.assert_editable!(invoice, invoice_id)
      if MyuctoInvoiceBinding.where(invoice_id: invoice_id.to_i).where.not(id: binding.id).exists?
        raise Myucto::Conflict, l(:error_myucto_invoice_already_bound)
      end
      binding.update!(invoice_id: invoice_id.to_i, connection_key: Myucto.connection_key, state: 'ready', error: nil)
    end
    flash[:notice] = l(:notice_myucto_invoice_attached)
  rescue Myucto::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    flash[:error] = e.is_a?(Myucto::Conflict) ? e.message : l(:error_myucto_recovery_failed)
  ensure
    redirect_to project_myucto_path(@project) unless performed?
  end

  def resume_event
    event = project_events.find(params[:id])
    event.with_lock do
      unless params[:confirm_recovery] == '1' && %w[conflict processing].include?(event.state)
        flash[:error] = l(:error_myucto_confirmation_required)
        next
      end
      if event.state == 'processing' && params[:worker_stopped] != '1'
        flash[:error] = l(:error_myucto_worker_active)
        next
      end
      if MyuctoInvoiceBinding.where(project_id: @project.id, state: %w[uncertain creating conflict]).exists?
        flash[:error] = l(:error_myucto_unsafe_retry)
        next
      end
      event.update!(state: 'pending', last_error: nil, available_at: Time.current)
      flash[:notice] = l(:notice_myucto_retry_queued)
    end
    redirect_to project_myucto_path(@project)
  end

  def suppliers
    # Administrator explicitly chooses the destination URL. The API token stays
    # on the server and is never accepted from, or returned to, the browser.
    config = Myucto.configuration.merge('base_url' => params.require(:base_url).to_s)
    result = Myucto::Client.new(config, discovery: true).supplier_choices
    response.headers['Cache-Control'] = 'no-store'
    render json: result
  rescue Myucto::Error
    render json: { error: l(:error_myucto_suppliers_failed) }, status: :unprocessable_entity
  end

  def test_connection
    result = Myucto::Client.new.test_connection
    supplier = result['supplier']
    unless supplier.is_a?(Hash) && supplier['id'].to_s == Myucto.configuration['supplier_id'].to_s
      raise Myucto::Conflict, l(:error_myucto_supplier_mismatch)
    end
    unless result['token'].is_a?(Hash) && result['token']['scope'] == 'read_write'
      raise Myucto::Conflict, l(:error_myucto_scope)
    end
    flash[:notice] = l(:notice_myucto_connection_ok)
  rescue Myucto::Error
    flash[:error] = l(:error_myucto_connection_failed)
  ensure
    redirect_to plugin_settings_path(:redmine_myucto)
  end

  private

  def find_myucto_project
    @project = Project.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def load_status
    @myucto_setting ||= MyuctoProjectSetting.find_or_initialize_by(project_id: @project.id)
    @bindings = MyuctoInvoiceBinding.where(project_id: @project.id).order(period: :desc)
    @events = project_events.order(id: :desc).limit(100)
    @retry_safe = @bindings.all?(&:automatic_retry_safe?)
  end

  def project_events
    linked_entries = MyuctoTimeLink.where(invoice_binding_id: MyuctoInvoiceBinding.where(project_id: @project.id).select(:id)).select(:time_entry_id)
    MyuctoSyncEvent.where(project_id: @project.id).or(MyuctoSyncEvent.where(time_entry_id: linked_entries))
  end

  def load_clients
    client = Myucto::Client.new
    client.verify_connection!
    @clients = client.clients
  rescue StandardError
    @clients = []
    @myucto_clients_error = l(:error_myucto_api_unavailable)
  end

  def client_value(client, key)
    client[key] || client[key.to_sym]
  end
  helper_method :client_value

  def remote_invoice_url(invoice_id)
    return nil unless invoice_id.to_s.match?(/\A[1-9]\d*\z/)
    uri = URI.parse(Myucto.configuration['base_url'].to_s)
    return nil unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
    uri.path = uri.path.sub(%r{/+\z}, '').sub(%r{/api/v1\z}, '') + "/invoices/#{invoice_id}"
    uri.query = nil
    uri.fragment = nil
    uri.to_s
  rescue URI::InvalidURIError
    nil
  end
  helper_method :remote_invoice_url
end
