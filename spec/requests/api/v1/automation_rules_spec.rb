# frozen_string_literal: true

require 'rails_helper'

# Request coverage for the automation rules permit (CRM-298): `values` is an
# array of scalars for regular operators and an object `{to: [], from: []}` for
# `attribute_changed`, so both shapes have to survive create and update. The
# rest pins what the hand-built permit drops.

AutomationRuleRequestEvent = Struct.new(:data) unless defined?(AutomationRuleRequestEvent)

RSpec.describe 'Api::V1::AutomationRules', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }
  let!(:label) { Label.create!(title: 'vip', color: '#abcdef') }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    response.parsed_body
  end

  def rule_payload(conditions:)
    {
      name: "regra-#{SecureRandom.hex(4)}",
      event_name: 'conversation_updated',
      active: true,
      mode: 'simple',
      conditions: conditions,
      actions: [{ action_name: 'change_priority', action_params: ['urgent'] }]
    }
  end

  def persisted_rule
    AutomationRule.find(json_response.dig('data', 'id'))
  end

  describe 'POST /api/v1/automation_rules' do
    it 'persists object-shaped values ({to, from}) for attribute_changed alongside array-shaped values' do
      payload = rule_payload(
        conditions: [
          { attribute_key: 'labels', filter_operator: 'attribute_changed', query_operator: 'AND',
            values: { to: [label.id], from: [] } },
          { attribute_key: 'status', filter_operator: 'equal_to', query_operator: '',
            values: ['open'] }
        ]
      )

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      conditions = persisted_rule.conditions
      expect(conditions[0]['values']).to eq({ 'to' => [label.id], 'from' => [] })
      expect(conditions[1]['values']).to eq(['open'])
    end

    it 'drops unknown keys from conditions and from object-shaped values' do
      payload = rule_payload(
        conditions: [
          { attribute_key: 'labels', filter_operator: 'attribute_changed', query_operator: '',
            forged: 'nope', values: { to: [label.id], evil: ['x'] } }
        ]
      )

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      condition = persisted_rule.conditions.first
      expect(condition).not_to have_key('forged')
      expect(condition['values']).to eq({ 'to' => [label.id] })
    end

    it 'persists a valueless condition (is_present) without a values key and without error' do
      payload = rule_payload(
        conditions: [
          { attribute_key: 'assignee_id', filter_operator: 'is_present', query_operator: '' }
        ]
      )

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(persisted_rule.conditions.first).not_to have_key('values')
    end

    it 'omits values when the array carries a non-scalar item' do
      payload = rule_payload(
        conditions: [
          { attribute_key: 'status', filter_operator: 'equal_to', query_operator: '', values: [{ id: 'x' }] }
        ]
      )

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(persisted_rule.conditions.first).not_to have_key('values')
    end

    it 'discards a condition item that is not an object' do
      payload = rule_payload(
        conditions: [
          'solta',
          { attribute_key: 'status', filter_operator: 'equal_to', query_operator: '', values: ['open'] }
        ]
      )

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(persisted_rule.conditions.map { |c| c['attribute_key'] }).to eq(['status'])
    end

    # Conditions are optional in the form, and a rule without them fires on
    # every event. Before CRM-298 the missing key reached the NOT NULL jsonb
    # column and answered 500.
    it 'stores an empty list when conditions are absent' do
      payload = rule_payload(conditions: []).except(:conditions)

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(persisted_rule.conditions).to eq([])
    end

    it 'ignores conditions sent as an object instead of an array' do
      payload = rule_payload(conditions: []).merge(
        conditions: { '0' => { attribute_key: 'status', filter_operator: 'equal_to', values: ['open'] } }
      )

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(persisted_rule.conditions).to eq([])
    end
  end

  describe 'PATCH /api/v1/automation_rules/:id' do
    let!(:rule) do
      AutomationRule.create!(
        name: 'regra-update', event_name: 'conversation_updated', active: true, mode: 'simple',
        conditions: [{ 'attribute_key' => 'status', 'filter_operator' => 'equal_to',
                       'query_operator' => '', 'values' => ['open'] }],
        actions: [{ 'action_name' => 'change_priority', 'action_params' => ['urgent'] }]
      )
    end

    it 'persists both values shapes on update' do
      payload = {
        conditions: [
          { attribute_key: 'labels', filter_operator: 'attribute_changed', query_operator: 'AND',
            values: { to: [label.id], from: [] } },
          { attribute_key: 'status', filter_operator: 'equal_to', query_operator: '',
            values: ['resolved'] }
        ]
      }

      patch "/api/v1/automation_rules/#{rule.id}", params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      conditions = rule.reload.conditions
      expect(conditions[0]['values']).to eq({ 'to' => [label.id], 'from' => [] })
      expect(conditions[1]['values']).to eq(['resolved'])
    end
  end

  describe 'an API-created attribute_changed rule fires' do
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
    let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
    let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

    it 'triggers the action service when the watched label is added' do
      payload = rule_payload(
        conditions: [
          { attribute_key: 'labels', filter_operator: 'attribute_changed', query_operator: '',
            values: { to: [label.id], from: [] } }
        ]
      )
      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      rule = persisted_rule

      event = AutomationRuleRequestEvent.new({
                                               conversation: conversation,
                                               changed_attributes: { 'label_list' => [[], ['vip']] }
                                             })
      service_double = instance_double(AutomationRules::ActionService, perform: nil)
      expect(AutomationRules::ActionService).to receive(:new)
        .with(rule, nil, conversation, hash_including(:recorder)).once.and_return(service_double)
      expect(service_double).to receive(:perform).once

      AutomationRuleListener.instance.conversation_updated(event)
    end
  end

  describe 'POST /api/v1/automation_rules/upload_attachment' do
    def uploaded_file
      path = File.join(Dir.mktmpdir, 'nota.txt')
      File.write(path, 'hello')
      Rack::Test::UploadedFile.new(path, 'text/plain')
    end

    it 'creates a blob and returns its id and filename' do
      post '/api/v1/automation_rules/upload_attachment', params: { file: uploaded_file }, headers: headers

      expect(response).to have_http_status(:created)
      data = json_response['data']
      expect(data['filename']).to eq('nota.txt')
      expect(ActiveStorage::Blob.find_by(id: data['id'])).to be_present
    end

    it 'rejects a request without a file' do
      post '/api/v1/automation_rules/upload_attachment', params: {}, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # `send_attachment` references ActiveStorage blobs; the rule only sends them at
  # runtime when they are attached to `rule.files` (the handler guards on
  # `@rule.files.attached?`), so create/update must attach the referenced blobs.
  describe 'send_attachment action_params' do
    def blob_for(filename)
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new('bytes'), filename: filename,
                                              content_type: 'application/pdf')
    end

    it 'attaches the referenced blobs to the rule files (array-of-hash shape)' do
      blob = blob_for('contrato.pdf')
      payload = rule_payload(conditions: []).merge(
        actions: [{ action_name: 'send_attachment', action_params: [{ attachment_ids: [blob.id], inbox_id: nil }] }]
      )

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      rule = persisted_rule
      expect(rule.files.attached?).to be(true)
      expect(rule.files.map(&:blob_id)).to include(blob.id)
    end

    it 'attaches blob ids from the legacy bare-id shape' do
      blob = blob_for('antigo.pdf')
      payload = rule_payload(conditions: []).merge(
        actions: [{ action_name: 'send_attachment', action_params: blob.id }]
      )

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(persisted_rule.files.map(&:blob_id)).to include(blob.id)
    end
  end
end
