# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Api::V1::Waha::Settings', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let(:session) { "evo-test-#{SecureRandom.hex(3)}" }
  let!(:user) { User.create!(name: 'WAHA User', email: "waha-#{SecureRandom.hex(4)}@example.com") }

  let!(:channel) do
    ch = Channel::Whatsapp.new(
      provider: 'waha',
      phone_number: "+1555#{SecureRandom.hex(3)}",
      provider_config: {
        'session' => session,
        'engine' => 'GOWS',
        'api_url' => 'http://old-waha.test',
        'api_key' => 'old-secret',
        'ignore_status' => true,
        'ignore_broadcast' => true
      }
    )
    ch.save!(validate: false)
    Inbox.create!(channel: ch, name: "WAHA #{SecureRandom.hex(3)}")
    ch
  end

  around do |example|
    original_base_url = ENV['EVO_AUTH_SERVICE_URL']
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
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

  before do
    stub_auth(role_key: 'agent', granted: %w[inboxes.update])
    # Saving the connection re-applies the WAHA webhook; stub the outbound PUT.
    stub_request(:put, %r{/api/sessions/})
      .to_return(status: 200, body: { name: 'session' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  it 'updates the connection override and preserves the rest of provider_config' do
    put '/api/v1/waha/settings',
        params: { session: session, api_url: 'https://waha.example.com', api_key: 'new-secret' },
        headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['success']).to be(true)
    expect(body['provider_config']['api_url']).to eq('https://waha.example.com')
    expect(body['provider_config']['api_key_configured']).to be(true)
    expect(body['provider_config']).not_to have_key('api_key')

    config = channel.reload.provider_config
    expect(config['api_url']).to eq('https://waha.example.com')
    expect(config['api_key']).to eq('new-secret')
    expect(config['engine']).to eq('GOWS')
    expect(config['ignore_status']).to be(true)
    expect(config['session']).to eq(session)
  end

  it 'keeps the current API key when it is left blank' do
    put '/api/v1/waha/settings',
        params: { session: session, api_url: 'https://waha.example.com', api_key: '' },
        headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(channel.reload.provider_config['api_key']).to eq('old-secret')
  end

  it 'clears the override and falls back to the global configuration' do
    put '/api/v1/waha/settings',
        params: { session: session, use_global: true },
        headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    config = channel.reload.provider_config
    expect(config).not_to have_key('api_url')
    expect(config).not_to have_key('api_key')
    expect(config['engine']).to eq('GOWS')
  end

  it 'requires a URL when overriding the server' do
    put '/api/v1/waha/settings',
        params: { session: session, api_url: '' },
        headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
  end
end
