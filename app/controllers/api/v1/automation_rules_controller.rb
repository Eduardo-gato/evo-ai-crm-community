class Api::V1::AutomationRulesController < Api::V1::BaseController
  include Api::V1::ResourceLimitsHelper

  require_permissions({
    index: 'automation_rules.read',
    show: 'automation_rules.read',
    create: 'automation_rules.create',
    update: 'automation_rules.update',
    destroy: 'automation_rules.delete',
    clone: 'automation_rules.clone',
    runs: 'automation_rules.read'
  })

  before_action :fetch_automation_rule, only: [:show, :update, :destroy, :clone, :runs]
  before_action :validate_automation_limit, only: [:create]
  before_action :check_upload_attachment_permission!, only: [:upload_attachment]

  private

  def fetch_automation_rule
    @automation_rule = AutomationRule.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::AUTOMATION_RULE_NOT_FOUND,
      "Automation rule with id #{params[:id]} not found",
      status: :not_found
    )
  end

  public

  def index
    @automation_rules = AutomationRule.all

    apply_pagination
    
    paginated_response(
      data: AutomationRuleSerializer.serialize_collection(@automation_rules),
      collection: @automation_rules,
      message: 'Automation rules retrieved successfully'
    )
  end

  def show
    success_response(
      data: AutomationRuleSerializer.serialize(@automation_rule),
      message: 'Automation rule retrieved successfully'
    )
  end

  def create
    @automation_rule = AutomationRule.new(automation_rules_permit)
    @automation_rule.actions = params[:actions]
    @automation_rule.conditions = permitted_conditions
    @automation_rule.flow_data = params[:flow_data] if params[:flow_data]

    unless @automation_rule.valid?
      return error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        details: @automation_rule.errors.full_messages,
        status: :unprocessable_entity
      )
    end

    @automation_rule.save!
    process_attachments
    
    success_response(
      data: AutomationRuleSerializer.serialize(@automation_rule),
      message: 'Automation rule created successfully',
      status: :created
    )
  end

  def update
    ActiveRecord::Base.transaction do
      automation_rule_update
      process_attachments
      
      success_response(
        data: AutomationRuleSerializer.serialize(@automation_rule),
        message: 'Automation rule updated successfully'
      )
    rescue StandardError => e
      Rails.logger.error e
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Update failed',
        details: @automation_rule.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    @automation_rule.destroy
    success_response(
      data: { id: @automation_rule.id },
      message: 'Automation rule deleted successfully'
    )
  end

  def clone
    new_rule = @automation_rule.dup
    new_rule.save!
    @automation_rule = new_rule

    success_response(
      data: AutomationRuleSerializer.serialize(@automation_rule),
      message: 'Automation rule cloned successfully',
      status: :created
    )
  end

  def runs
    runs_scope = @automation_rule.runs.recent.with_status(params[:status])
    @runs = runs_scope.limit(per_page).offset(page_offset)
    total = runs_scope.count

    success_response(
      data: @runs.map { |run| serialize_run(run) },
      meta: {
        pagination: {
          page: current_page,
          per_page: per_page,
          total_count: total,
          total_pages: (total / per_page.to_f).ceil
        }
      },
      message: 'Automation rule runs retrieved successfully'
    )
  end

  # Uploads a file from the operator's computer so it can be referenced by the
  # `send_attachment` action as an ActiveStorage blob id. Available before the
  # rule exists (/automation/new), hence a collection route with no rule id.
  def upload_attachment
    file = params[:file] || params[:attachment]
    if file.blank? || !file.respond_to?(:original_filename)
      return error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'File is required',
        status: :unprocessable_entity
      )
    end

    blob = ActiveStorage::Blob.create_and_upload!(
      io: file,
      filename: file.original_filename,
      content_type: file.content_type
    )

    success_response(
      data: {
        id: blob.id,
        signed_id: blob.signed_id,
        filename: blob.filename.to_s,
        content_type: blob.content_type,
        byte_size: blob.byte_size
      },
      message: 'Attachment uploaded successfully',
      status: :created
    )
  rescue StandardError => e
    Rails.logger.error "Automation rule attachment upload failed: #{e.class} - #{e.message}"
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Attachment upload failed', details: [e.message],
                                                                                  status: :unprocessable_entity)
  end

  def process_attachments
    attachment_blob_ids.each do |blob_id|
      blob = ActiveStorage::Blob.find_by(id: blob_id)
      @automation_rule.files.attach(blob) if blob
    end
  end

  private

  def attachment_blob_ids
    Array(@automation_rule.actions).flat_map do |action|
      action = plain_hash(action)
      next [] unless action['action_name'] == 'send_attachment'

      extract_blob_ids(action['action_params'])
    end.uniq
  end

  # `action_params` may be a bare id (legacy), a hash `{attachment_ids:, inbox_id:}`
  # or an array wrapping that hash (the current UI shape).
  def extract_blob_ids(params)
    case params
    when Array
      params.flat_map { |entry| blob_ids_from_entry(entry) }.compact
    else
      hash = plain_hash(params)
      hash.present? ? Array(hash['attachment_ids'] || hash[:attachment_ids]).compact : [params].compact
    end
  end

  def blob_ids_from_entry(entry)
    hash = plain_hash(entry)
    hash.present? ? Array(hash['attachment_ids'] || hash[:attachment_ids]) : [entry]
  end

  # `params[:actions]` may arrive as ActionController::Parameters (create) or as
  # a plain hash (read back from jsonb); normalize either to string-keyed hashes.
  def plain_hash(value)
    return {} unless value.respond_to?(:[])

    if value.respond_to?(:to_unsafe_h)
      value.to_unsafe_h
    elsif value.is_a?(Hash)
      value
    else
      {}
    end
  end

  # Upload is reachable from both the create (/new) and edit screens, so accept
  # either permission.
  def check_upload_attachment_permission!
    return if Current.service_authenticated == true

    user_id = Current.user&.id
    return render_permission_denied if user_id.blank?

    allowed = %w[automation_rules.create automation_rules.update].any? do |permission|
      has_user_permission?(user_id, permission)
    end
    render_permission_denied unless allowed
  end

  def automation_rule_update
    @automation_rule.update!(automation_rules_permit)
    @automation_rule.actions = params[:actions] if params[:actions]
    @automation_rule.conditions = permitted_conditions if params[:conditions]
    @automation_rule.flow_data = params[:flow_data] if params[:flow_data]
    @automation_rule.save!
  end

  def serialize_run(run)
    {
      id: run.id,
      automation_rule_id: run.automation_rule_id,
      event_name: run.event_name,
      status: run.status,
      started_at: run.started_at&.iso8601,
      finished_at: run.finished_at&.iso8601,
      duration_ms: run.duration_ms,
      error_message: run.error_message,
      payload: run.payload,
      steps: run.steps
    }
  end

  def current_page
    [params[:page].to_i, 1].max
  end

  def per_page
    [(params[:per_page] || 25).to_i, 100].min
  end

  def page_offset
    (current_page - 1) * per_page
  end

  # `values` is an array of scalars for regular operators but an object
  # `{to: [], from: []}` for `attribute_changed` (the shape
  # ConditionsFilterService reads), and `permit` cannot declare "array OR hash"
  # for one key — so each condition is permitted by hand.
  def permitted_conditions
    return [] unless params[:conditions].is_a?(Array)

    params[:conditions].filter_map do |condition|
      next unless condition.is_a?(ActionController::Parameters)

      permitted = condition.permit(:attribute_key, :filter_operator, :query_operator, :custom_attribute_type)
      permit_values(condition, permitted)
      permitted.to_h
    end
  end

  # An array whose items are not all scalars is rejected whole by `permit`,
  # which returns nil — leave `values` out entirely in that case, the way a
  # valueless condition (`is_present`) is stored.
  def permit_values(condition, permitted)
    values = condition[:values]

    if values.is_a?(ActionController::Parameters)
      permitted[:values] = values.permit(to: [], from: [])
    elsif values.is_a?(Array)
      scalars = condition.permit(values: [])[:values]
      permitted[:values] = scalars unless scalars.nil?
    end
  end

  def automation_rules_permit
    params.permit(
      :name, :description, :event_name, :active, :mode,
      actions: [:action_name, { action_params: [] }],
      flow_data: {
        nodes: [
          :id, :type,
          position: [:x, :y],
          data: {},
          measured: [:width, :height]
        ],
        edges: [
          :id, :source, :target, :sourceHandle, :targetHandle,
          data: {}
        ],
        variables: [
          :id, :name, :type, :default_value,
          data: {}
        ]
      }
    )
  end
end
