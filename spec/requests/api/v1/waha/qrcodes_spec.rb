# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Api::V1::Waha::Qrcodes', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let(:session) { "dudu-#{SecureRandom.hex(3)}" }
  let!(:user) { User.create!(name: 'WAHA User', email: "waha-#{SecureRandom.hex(4)}@example.com") }

  let!(:channel) do
    ch = Channel::Whatsapp.new(
      provider: 'waha',
      phone_number: "+1555#{SecureRandom.hex(3)}",
      provider_config: { 'api_url' => 'http://waha.test', 'api_key' => 'secret', 'session' => session }
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

  before { stub_auth(role_key: 'agent', granted: %w[inboxes.read]) }

  it 'fetches the QR code from WAHA with GET and returns the base64 image' do
    stub_request(:get, "http://waha.test/api/#{session}/auth/qr")
      .with(headers: { 'X-Api-Key' => 'secret' })
      .to_return(
        status: 200,
        body: { mimetype: 'image/png', data: 'iVBORw0KGgo=' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    get "/api/v1/waha/qrcodes/#{session}", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['success']).to be(true)
    expect(body['qrcode']).to eq('iVBORw0KGgo=')
  end

  it 'returns 502 when WAHA rejects the QR request' do
    stub_request(:get, "http://waha.test/api/#{session}/auth/qr")
      .to_return(status: 404, body: { message: 'Not Found' }.to_json, headers: { 'Content-Type' => 'application/json' })

    get "/api/v1/waha/qrcodes/#{session}", headers: headers, as: :json

    expect(response).to have_http_status(:bad_gateway)
  end
end
