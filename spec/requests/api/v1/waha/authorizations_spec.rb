# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Api::V1::Waha::Authorizations', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:user) { User.create!(name: 'WAHA User', email: "waha-#{SecureRandom.hex(4)}@example.com") }

  let(:authorization) do
    {
      api_url: 'http://waha.test',
      api_key: 'secret',
      session: 'default',
      engine: 'GOWS',
      webhook_hmac_key: 'hmac-secret'
    }
  end

  around do |example|
    original_base_url = ENV['EVO_AUTH_SERVICE_URL']
    original_backend_url = ENV['BACKEND_URL']
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    ENV['BACKEND_URL'] = 'http://crm.test'
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
    ENV['BACKEND_URL'] = original_backend_url
  end

  def stub_auth(role_key:, granted: [])
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: {
          success: true,
          data: { user: { id: user.id, email: user.email, role: { id: 1, key: role_key, name: role_key } } }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return do |request|
        permission_key = JSON.parse(request.body)['permission_key']
        {
          status: 200,
          body: { success: true, data: { has_permission: granted.include?(permission_key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
  end

  before { stub_auth(role_key: 'agent', granted: %w[inboxes.create]) }

  it 'reuses an existing WAHA session by updating it with PUT' do
    stub_request(:post, 'http://waha.test/api/sessions')
      .with(headers: { 'X-Api-Key' => 'secret' })
      .to_return(
        status: 422,
        body: { message: "Session 'default' already exists. Use PUT to update it." }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
    stub_request(:put, 'http://waha.test/api/sessions/default')
      .with(headers: { 'X-Api-Key' => 'secret' })
      .to_return(
        status: 200,
        body: { name: 'default', status: 'STARTING' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    post '/api/v1/waha/authorization', params: { authorization: authorization }, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body['success']).to be(true)
    expect(body['reused']).to be(true)
    expect(body['session']).to eq('default')
  end

  it 'returns 502 when WAHA rejects the session creation with an unexpected error' do
    stub_request(:post, 'http://waha.test/api/sessions')
      .to_return(status: 500, body: { message: 'boom' }.to_json, headers: { 'Content-Type' => 'application/json' })

    post '/api/v1/waha/authorization', params: { authorization: authorization }, headers: headers, as: :json

    expect(response).to have_http_status(:bad_gateway)
  end

  it 'generates a unique session name when none is provided' do
    captured = nil
    stub_request(:post, 'http://waha.test/api/sessions')
      .with(headers: { 'X-Api-Key' => 'secret' }) do |request|
        captured = JSON.parse(request.body)
        true
      end
      .to_return(status: 201, body: { name: 'generated', status: 'STARTING' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })

    post '/api/v1/waha/authorization',
         params: { authorization: authorization.except(:session) },
         headers: headers, as: :json

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)['session']).to match(/\Aevo-/)
    expect(captured['name']).to match(/\Aevo-/)
  end

  it 'references an existing session when a session-scoped key forbids creation' do
    stub_request(:post, 'http://waha.test/api/sessions')
      .to_return(status: 403, body: { message: 'Forbidden' }.to_json, headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, 'http://waha.test/api/sessions/default')
      .to_return(status: 200, body: { name: 'default', status: 'WORKING' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })

    post '/api/v1/waha/authorization', params: { authorization: authorization }, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body['success']).to be(true)
    expect(body['reused']).to be(true)
  end

  it 'returns an actionable error when a forbidden key cannot reach the session' do
    stub_request(:post, 'http://waha.test/api/sessions')
      .to_return(status: 403, body: { message: 'Forbidden' }.to_json, headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, 'http://waha.test/api/sessions/default')
      .to_return(status: 403, body: { message: 'Forbidden' }.to_json, headers: { 'Content-Type' => 'application/json' })

    post '/api/v1/waha/authorization', params: { authorization: authorization }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to include('403')
  end
end
