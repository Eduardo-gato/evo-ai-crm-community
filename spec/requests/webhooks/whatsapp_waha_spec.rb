# frozen_string_literal: true

require 'rails_helper'
require 'openssl'

RSpec.describe 'Webhooks::Whatsapp WAHA', type: :request do
  let(:secret) { 'hmac-secret' }
  let(:session_name) { "support-#{SecureRandom.hex(3)}" }
  let(:payload) do
    {
      id: "evt-#{SecureRandom.hex(4)}",
      event: 'message.any',
      session: session_name,
      payload: { id: 'false_1', from: '5511999999999@c.us', fromMe: false, body: 'oi' }
    }
  end

  def create_waha_channel!
    channel = Channel::Whatsapp.new(
      provider: 'waha',
      phone_number: "+1555#{SecureRandom.hex(3)}",
      provider_config: { 'session' => session_name, 'webhook_hmac_key' => secret }
    )
    channel.save!(validate: false)
    Inbox.create!(channel: channel, name: "WAHA #{SecureRandom.hex(3)}")
    channel
  end

  def post_waha(body, signature: nil, path: '/webhooks/whatsapp/waha')
    headers = { 'CONTENT_TYPE' => 'application/json' }
    headers['X-Webhook-Hmac'] = signature if signature
    post path, params: body, headers: headers
  end

  before { allow(Webhooks::WhatsappEventsJob).to receive(:perform_later) }

  it 'accepts a valid HMAC and enqueues the event job' do
    create_waha_channel!
    body = payload.to_json
    signature = OpenSSL::HMAC.hexdigest('SHA512', secret, body)

    post_waha(body, signature: signature)

    expect(response).to have_http_status(:ok)
    expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).once
  end

  it 'also serves the /api/v1 webhook path (absolute controller route)' do
    create_waha_channel!
    body = payload.to_json
    signature = OpenSSL::HMAC.hexdigest('SHA512', secret, body)

    post_waha(body, signature: signature, path: '/api/v1/webhooks/whatsapp/waha')

    expect(response).to have_http_status(:ok)
    expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).once
  end

  it 'rejects a payload with an invalid HMAC' do
    create_waha_channel!
    body = payload.to_json

    post_waha(body, signature: 'deadbeef')

    expect(response).to have_http_status(:unauthorized)
    expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
  end

  it 'rejects a payload with no HMAC header' do
    create_waha_channel!

    post_waha(payload.to_json)

    expect(response).to have_http_status(:unauthorized)
    expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
  end

  it 'rejects events for an unknown session' do
    body = payload.merge(session: 'unknown-session').to_json
    signature = OpenSSL::HMAC.hexdigest('SHA512', secret, body)

    post_waha(body, signature: signature)

    expect(response).to have_http_status(:unauthorized)
    expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
  end

  it 'does not associate WAHA events with an Evolution Go channel' do
    channel = Channel::Whatsapp.new(
      provider: 'evolution_go',
      phone_number: "+1555#{SecureRandom.hex(3)}",
      provider_config: { 'session' => session_name }
    )
    channel.save!(validate: false)
    Inbox.create!(channel: channel, name: "EVO GO #{SecureRandom.hex(3)}")

    body = payload.to_json
    signature = OpenSSL::HMAC.hexdigest('SHA512', secret, body)

    post_waha(body, signature: signature)

    expect(response).to have_http_status(:unauthorized)
    expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
  end

  it 'rejects a malformed JSON body' do
    post_waha('not-json')

    expect(response).to have_http_status(:bad_request)
  end
end
