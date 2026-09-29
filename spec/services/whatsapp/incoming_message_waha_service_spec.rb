# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::IncomingMessageWahaService do
  let(:channel) { instance_double(Channel::Whatsapp) }
  let(:inbox) { instance_double(Inbox, channel: channel) }
  let(:service) { described_class.new(inbox: inbox, params: params) }

  describe 'message.any for an inbound message' do
    let(:params) do
      {
        event: 'message.any',
        payload: {
          id: 'false_5511999999999@c.us_ABC',
          from: '5511999999999@c.us',
          fromMe: false,
          body: 'Ola',
          pushName: 'Ana'
        }
      }
    end

    it 'normalizes the WAHA payload into the CRM message shape' do
      normalized = service.send(:normalize_message)

      expect(normalized[:messages].first).to include(
        id: 'false_5511999999999@c.us_ABC',
        from: '5511999999999@c.us',
        type: 'text'
      )
      expect(normalized[:messages].first[:text]).to eq(body: 'Ola')
      expect(normalized[:contacts].first).to include(wa_id: '5511999999999@c.us')
      expect(normalized[:contacts].first[:profile]).to eq(name: 'Ana')
    end

    it 'runs the shared base funnel' do
      allow(service).to receive(:process_messages)

      service.perform

      expect(service).to have_received(:process_messages)
      expect(service.send(:processed_params)[:messages].first[:type]).to eq('text')
    end
  end

  describe 'message.any echo of an outgoing message' do
    let(:params) do
      { event: 'message.any', payload: { id: 'false_out', from: '5511999999999@c.us', fromMe: true, body: 'sent' } }
    end

    it 'does not create a duplicate incoming message' do
      expect(service).not_to receive(:process_messages)

      service.perform
    end
  end

  describe 'message.any from a status broadcast' do
    let(:params) do
      { event: 'message.any', payload: { id: 'false_status', from: 'status@broadcast', fromMe: false, body: '' } }
    end

    it 'is ignored instead of failing source_id validation' do
      expect(service).not_to receive(:process_messages)

      service.perform
    end
  end

  describe 'message.any with media' do
    let(:params) do
      {
        event: 'message.any',
        payload: {
          id: 'false_img',
          from: '5511999999999@c.us',
          fromMe: false,
          body: 'legenda',
          media: { url: 'http://waha.test/api/files/img-1', mimetype: 'image/jpeg', filename: 'foto.jpg' }
        }
      }
    end

    it 'classifies the mimetype and keeps the media url as the attachment id' do
      message = service.send(:normalize_message)[:messages].first

      expect(message[:type]).to eq('image')
      expect(message[:image]).to include(
        id: 'http://waha.test/api/files/img-1',
        caption: 'legenda',
        filename: 'foto.jpg',
        mimetype: 'image/jpeg'
      )
    end
  end

  describe 'message.ack' do
    let(:params) { { event: 'message.ack', payload: { id: 'waha-message-1', ackName: 'READ' } } }
    let(:message) { instance_double(Message) }
    let(:relation) { instance_double(ActiveRecord::AssociationRelation) }
    let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

    before do
      allow(inbox).to receive(:messages).and_return(relation)
      allow(relation).to receive(:find_by).with(source_id: 'waha-message-1').and_return(message)
    end

    it 'maps READ to the read status' do
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'read', nil).and_return(status_service)

      service.perform
    end

    it 'maps ERROR to the failed status with a delivery error' do
      params[:payload][:ackName] = 'ERROR'
      expect(Messages::StatusUpdateService).to receive(:new)
        .with(message, 'failed', 'WAHA reported a delivery error')
        .and_return(status_service)

      service.perform
    end

    it 'ignores unknown ack states' do
      params[:payload][:ackName] = 'PENDING'
      expect(Messages::StatusUpdateService).not_to receive(:new)

      service.perform
    end
  end

  describe 'session.status' do
    let(:params) { { event: 'session.status', payload: { status: 'WORKING' } } }

    it 'marks the channel connected when WORKING' do
      provider = instance_double(Whatsapp::Providers::WahaService)
      allow(channel).to receive(:provider_service).and_return(provider)
      expect(channel).to receive(:mark_connected!)
      expect(provider).to receive(:sync_connected_phone!)

      service.perform
    end

    it 'marks the channel disconnected and prompts reauthorization when FAILED' do
      params[:payload][:status] = 'FAILED'

      expect(channel).to receive(:prompt_reauthorization!)
      expect(channel).to receive(:update_provider_connection!).with(
        hash_including('connection' => 'disconnected')
      )

      service.perform
    end
  end

  describe 'message.revoked' do
    let(:params) { { event: 'message.revoked', payload: { revoked_message_id: 'false_rev' } } }

    it 'marks the original message as revoked by the contact' do
      expect(service).to receive(:mark_message_revoked_by_source_id).with('false_rev')

      service.perform
    end
  end

  describe 'message.edited' do
    let(:params) { { event: 'message.edited', payload: { edited_message_id: 'waha-1', body: 'novo texto' } } }
    let(:message) { instance_double(Message) }
    let(:relation) { instance_double(ActiveRecord::AssociationRelation) }

    it 'updates the stored message content' do
      allow(inbox).to receive(:messages).and_return(relation)
      allow(relation).to receive(:find_by).with(source_id: 'waha-1').and_return(message)
      expect(message).to receive(:update!).with(content: 'novo texto')

      service.perform
    end
  end

  describe '#normalized_jid' do
    let(:params) { {} }

    it 'normalizes the Baileys JID into the WAHA chat JID' do
      expect(service.send(:normalized_jid, '5511999999999@s.whatsapp.net')).to eq('5511999999999@c.us')
      expect(service.send(:normalized_jid, '+5511999999999')).to eq('5511999999999')
      expect(service.send(:normalized_jid, '123@g.us')).to eq('123@g.us')
    end
  end

  describe '#contact_source_id' do
    let(:params) { {} }

    it 'strips the @c.us suffix so the contact_inbox source_id passes validation' do
      expect(service.send(:contact_source_id, '5511999999999@c.us')).to eq('5511999999999')
      expect(service.send(:contact_source_id, '5511999999999@s.whatsapp.net')).to eq('5511999999999')
    end

    it 'strips a device suffix from phone JIDs' do
      expect(service.send(:contact_source_id, '556291969008:92@s.whatsapp.net')).to eq('556291969008')
    end

    it 'keeps @lid and @g.us JIDs untouched' do
      expect(service.send(:contact_source_id, '100712839131186@lid')).to eq('100712839131186@lid')
      expect(service.send(:contact_source_id, '120363025801848701@g.us')).to eq('120363025801848701@g.us')
    end

    it 'rejects status broadcasts' do
      expect(service.send(:contact_source_id, 'status@broadcast')).to be_nil
    end
  end

  describe '#contact_name' do
    let(:params) do
      { event: 'message.any', payload: { from: '168422931472444@lid', _data: { notifyName: 'Jaque' } } }
    end

    it 'prefers the WAHA notify name over the raw JID' do
      expect(service.send(:contact_name, '168422931472444@lid', nil)).to eq('Jaque')
    end

    it 'falls back to the phone number when no name is reported' do
      allow(service).to receive(:payload).and_return({ from: '5511999999999@c.us' })
      expect(service.send(:contact_name, '5511999999999', '+5511999999999')).to eq('+5511999999999')
    end
  end

  describe '#resolved_from (@lid unification)' do
    let(:params) do
      { event: 'message.any', payload: { id: 'x', from: '168422931472444@lid', fromMe: false, body: 'oi' } }
    end

    before do
      allow(channel).to receive(:provider_config).and_return({ 'session' => 'default' })
      Rails.cache.clear
    end

    it 'resolves a @lid to the phone JID via the WAHA LID API' do
      provider = instance_double(Whatsapp::Providers::WahaService, resolve_lid: '5511999999999')
      allow(channel).to receive(:provider_service).and_return(provider)

      expect(service.send(:resolved_from)).to eq('5511999999999@c.us')
    end

    it 'prefers the phone JID present in the raw payload' do
      allow(service).to receive(:payload).and_return(
        { from: '168422931472444@lid', _data: { key: { remoteJidAlt: '5511999999999@c.us' } } }
      )

      expect(service.send(:resolved_from)).to eq('5511999999999@c.us')
    end

    it 'resolves the phone JID from SenderAlt, stripping the device suffix' do
      allow(service).to receive(:payload).and_return(
        { from: '168422931472444@lid', _data: { Info: { SenderAlt: '556291969008:92@s.whatsapp.net' } } }
      )

      expect(service.send(:resolved_from)).to eq('556291969008@s.whatsapp.net')
    end

    it 'keeps the @lid when it cannot be resolved' do
      provider = instance_double(Whatsapp::Providers::WahaService, resolve_lid: nil)
      allow(channel).to receive(:provider_service).and_return(provider)

      expect(service.send(:resolved_from)).to eq('168422931472444@lid')
    end
  end

  describe 'media metadata resolution' do
    let(:params) { { event: 'message.any', payload: { id: 'x', from: '5511@c.us', fromMe: false, media: {} } } }

    it 'uses media.mimetype when present' do
      media = { mimetype: 'image/png', filename: nil }

      expect(service.send(:media_type, media)).to eq('image')
      expect(service.send(:media_extension, nil, media)).to eq('png')
    end

    it 'falls back to the raw engine message for mimetype and filename' do
      params[:payload][:media] = { url: 'http://waha.test/api/files/doc-1', filename: nil, mimetype: nil }
      params[:payload][:_data] = {
        message: { documentMessage: { mimetype: 'application/pdf', fileName: 'contrato.pdf' } }
      }

      expect(service.send(:media_type, params[:payload][:media])).to eq('document')
      expect(service.send(:media_mimetype, params[:payload][:media])).to eq('application/pdf')
      expect(service.send(:media_filename, params[:payload][:media])).to eq('contrato.pdf')
      expect(service.send(:media_extension, 'contrato.pdf', params[:payload][:media])).to eq('pdf')
    end

    it 'unwraps documentWithCaptionMessage wrappers' do
      params[:payload][:_data] = {
        message: {
          documentWithCaptionMessage: {
            message: { documentMessage: { mimetype: 'application/pdf', fileName: 'nota.pdf' } }
          }
        }
      }

      expect(service.send(:media_mimetype, {})).to eq('application/pdf')
      expect(service.send(:media_filename, {})).to eq('nota.pdf')
    end
  end
end
