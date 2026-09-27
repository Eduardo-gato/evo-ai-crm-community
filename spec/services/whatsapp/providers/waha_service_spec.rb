# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Whatsapp::Providers::WahaService do
  let(:whatsapp_channel) do
    instance_double(
      Channel::Whatsapp,
      provider_config: {
        'api_url' => 'http://waha.test',
        'api_key' => 'secret',
        'session' => 'support'
      }
    )
  end
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  it 'validates the minimum channel configuration without exposing secrets' do
    expect(service.validate_provider_config?).to be(true)
    expect(service.api_headers).to eq(
      'X-Api-Key' => 'secret',
      'Content-Type' => 'application/json',
      'Accept' => 'application/json'
    )
  end

  describe '.normalize_api_url' do
    it 'defaults a scheme-less host to https' do
      expect(described_class.normalize_api_url('apiwa.biia.top')).to eq('https://apiwa.biia.top')
    end

    it 'keeps an explicit scheme' do
      expect(described_class.normalize_api_url('http://waha:3000')).to eq('http://waha:3000')
    end

    it 'returns a blank value unchanged' do
      expect(described_class.normalize_api_url('')).to eq('')
    end
  end

  it 'sends text using a WAHA chat JID and returns the provider id' do
    stub_request(:post, 'http://waha.test/api/sendText')
      .with(
        headers: { 'X-Api-Key' => 'secret' },
        body: hash_including(session: 'support', chatId: '5511999999999@c.us', text: 'Hello')
      )
      .to_return(status: 201, body: { id: 'waha-message-1' }.to_json, headers: { 'Content-Type' => 'application/json' })

    message = instance_double(
      Message,
      attachments: [],
      content_type: 'text',
      content: 'Hello',
      content_attributes: {}
    )

    expect(service.send_message('+5511999999999', message)).to eq('waha-message-1')
  end

  it 'sends attachments inline as base64 so an external WAHA can deliver them' do
    stub_request(:post, 'http://waha.test/api/sendImage')
      .with(body: hash_including(
        session: 'support',
        chatId: '5511999999999@c.us',
        file: hash_including(
          'mimetype' => 'image/png',
          'filename' => 'a.png',
          'data' => Base64.strict_encode64('hello')
        )
      ))
      .to_return(status: 201, body: { id: 'img-1' }.to_json, headers: { 'Content-Type' => 'application/json' })

    blob = instance_double(ActiveStorage::Blob, byte_size: 5)
    attached = double('file', content_type: 'image/png', filename: 'a.png', blob: blob, download: 'hello')
    attachment = instance_double(Attachment, file_type: 'image', file: attached)
    message = instance_double(
      Message,
      attachments: [attachment],
      content: 'legenda',
      content_type: 'text',
      content_attributes: {}
    )

    expect(service.send_message('+5511999999999', message)).to eq('img-1')
  end

  it 'keeps group JIDs unchanged' do    stub_request(:post, 'http://waha.test/api/sendText')
      .with(body: hash_including(chatId: '123@g.us'))
      .to_return(status: 201, body: { id: 'group-message' }.to_json, headers: { 'Content-Type' => 'application/json' })

    message = instance_double(Message, attachments: [], content_type: 'text', content: 'Hello', content_attributes: {})

    expect(service.send_message('123@g.us', message)).to eq('group-message')
  end

  it 'extracts the serialized id from the WAHA message-key response' do
    stub_request(:post, 'http://waha.test/api/sendText')
      .to_return(
        status: 201,
        body: {
          id: { fromMe: true, remote: '5511999999999@c.us', id: '3EB0ABC', _serialized: 'true_5511999999999@c.us_3EB0ABC_out' },
          ack: 1,
          body: 'Hello'
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    message = instance_double(Message, attachments: [], content_type: 'text', content: 'Hello', content_attributes: {})

    expect(service.send_message('+5511999999999', message)).to eq('true_5511999999999@c.us_3EB0ABC_out')
  end

  describe '#sync_connected_phone!' do
    let(:relation) { instance_double('ChannelRelation') }

    before do
      allow(Channel::Whatsapp).to receive(:where).and_return(relation)
      allow(relation).to receive(:where).and_return(relation)
      allow(relation).to receive(:not).and_return(relation)
      allow(relation).to receive(:exists?).and_return(false)
    end

    it 'reads /me and backfills the phone number for a WAHA channel' do
      channel = instance_double(
        Channel::Whatsapp,
        provider_config: { 'api_url' => 'http://waha.test', 'api_key' => 'secret', 'session' => 'support' },
        phone_number: nil,
        id: 'channel-1'
      )
      service = described_class.new(whatsapp_channel: channel)

      stub_request(:get, 'http://waha.test/api/sessions/support/me')
        .to_return(status: 200, body: { id: '5511888888888@c.us', pushName: 'Ana' }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      expect(channel).to receive(:update_columns) do |updates|
        expect(updates[:phone_number]).to eq('+5511888888888')
        expect(updates[:provider_config]['me']).to include('id' => '5511888888888@c.us')
      end

      service.sync_connected_phone!
    end

    it 'keeps the number only in provider_config when it belongs to another channel' do
      channel = instance_double(
        Channel::Whatsapp,
        provider_config: { 'api_url' => 'http://waha.test', 'api_key' => 'secret', 'session' => 'support' },
        phone_number: nil,
        id: 'channel-1'
      )
      service = described_class.new(whatsapp_channel: channel)
      allow(relation).to receive(:exists?).and_return(true)

      stub_request(:get, 'http://waha.test/api/sessions/support/me')
        .to_return(status: 200, body: { id: '5511888888888@c.us' }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      expect(channel).to receive(:update_columns) do |updates|
        expect(updates).not_to have_key(:phone_number)
        expect(updates[:provider_config]['me']).to include('id' => '5511888888888@c.us')
      end

      service.sync_connected_phone!
    end
  end
end
