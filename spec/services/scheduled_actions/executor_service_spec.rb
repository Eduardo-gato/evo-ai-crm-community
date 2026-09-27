# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScheduledActions::ExecutorService do
  subject(:service) { described_class.new(scheduled_action) }

  let(:contact) { instance_double(Contact, phone_number: '+5511999999999', contact_inboxes: contact_inboxes) }
  let(:contact_inboxes) { instance_double(ActiveRecord::Relation) }
  let(:scheduled_action) { instance_double(ScheduledAction, contact: contact, conversation: nil) }

  let(:whatsapp_inbox) { instance_double(Inbox, id: 'wa-inbox') }
  let(:whatsapp_cloud_inbox) { instance_double(Inbox, id: 'wa-cloud-inbox') }
  let(:sms_inbox) { instance_double(Inbox) }
  let(:telegram_inbox) { instance_double(Inbox, id: 'telegram-inbox') }
  let(:sms_scope) { instance_double(ActiveRecord::Relation, first: sms_inbox) }
  let(:telegram_scope) { instance_double(ActiveRecord::Relation, first: telegram_inbox) }
  let(:telegram_contact_inbox) { instance_double(ContactInbox, source_id: 'telegram-source-id') }

  describe '#channel_config' do
    it 'uses Channel::Whatsapp when available and the phone as source id' do
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::Whatsapp').and_return(whatsapp_inbox)
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::WhatsappCloud')
      allow(contact_inboxes).to receive(:find_by).with(inbox_id: 'wa-inbox').and_return(nil)

      config = service.send(:channel_config, 'whatsapp')

      expect(config[:inbox]).to eq(whatsapp_inbox)
      expect(config[:source_id]).to eq('5511999999999')
    end

    it 'prefers the existing contact_inbox source id (WAHA/Evolution JID)' do
      contact_inbox = instance_double(ContactInbox, source_id: '5511999999999@c.us')
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::Whatsapp').and_return(whatsapp_inbox)
      allow(contact_inboxes).to receive(:find_by).with(inbox_id: 'wa-inbox').and_return(contact_inbox)

      config = service.send(:channel_config, 'whatsapp')

      expect(config[:source_id]).to eq('5511999999999@c.us')
    end

    it 'falls back to Channel::WhatsappCloud when Channel::Whatsapp is unavailable' do
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::Whatsapp').and_return(nil)
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::WhatsappCloud').and_return(whatsapp_cloud_inbox)
      allow(contact_inboxes).to receive(:find_by).with(inbox_id: 'wa-cloud-inbox').and_return(nil)

      config = service.send(:channel_config, 'whatsapp')

      expect(config[:inbox]).to eq(whatsapp_cloud_inbox)
      expect(config[:source_id]).to eq('5511999999999')
    end

    it 'returns a not configured error when no WhatsApp inbox exists' do
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::Whatsapp').and_return(nil)
      allow(Inbox).to receive(:find_by).with(channel_type: 'Channel::WhatsappCloud').and_return(nil)

      config = service.send(:channel_config, 'whatsapp')

      expect(config).to eq(
        success: false,
        error: 'WhatsApp not configured for this account'
      )
    end

    it 'resolves sms channel config with Channel::Sms inbox and phone source id' do
      allow(Inbox).to receive(:where).with(channel_type: 'Channel::Sms').and_return(sms_scope)

      config = service.send(:channel_config, 'sms')

      expect(config[:inbox]).to eq(sms_inbox)
      expect(config[:source_id]).to eq('+5511999999999')
      expect(config[:error_msg]).to eq('SMS not configured')
    end

    it 'resolves telegram channel config with existing contact inbox source id' do
      allow(Inbox).to receive(:where).with(channel_type: 'Channel::Telegram').and_return(telegram_scope)
      allow(contact_inboxes).to receive(:find_by).with(inbox_id: 'telegram-inbox').and_return(telegram_contact_inbox)

      config = service.send(:channel_config, 'telegram')

      expect(config[:inbox]).to eq(telegram_inbox)
      expect(config[:source_id]).to eq('telegram-source-id')
      expect(config[:error_msg]).to eq('Telegram not configured')
    end

    it 'returns an explicit error for unknown channel values' do
      config = service.send(:channel_config, 'unknown')

      expect(config).to eq(
        success: false,
        error: 'Unknown channel: unknown'
      )
    end
  end

  describe '#execute_send_message with only a conversation (chat composer)' do
    let(:conversation) { instance_double(Conversation, contact: contact) }
    let(:scheduled_action) { instance_double(ScheduledAction, contact: nil, conversation: conversation) }

    it 'resolves the contact from the conversation and routes to it' do
      allow(service).to receive(:execute_send_message_to_conversation).and_return(success: true, data: {})

      expect(service.send(:execute_send_message)).to eq(success: true, data: {})
      expect(service.send(:contact)).to eq(contact)
    end

    it 'does not bail out with Contact not found when only conversation_id is set' do
      allow(service).to receive(:execute_send_message_to_conversation).and_return(success: true, data: {})
      allow(scheduled_action).to receive(:payload).and_return({ 'channel' => 'whatsapp' })

      result = service.send(:execute_send_message)

      expect(result[:success]).to be(true)
    end
  end

  describe '#attach_scheduled_files' do
    let(:file_blob) { instance_double(ActiveStorage::Blob) }
    let(:scheduled_action) do
      instance_double(
        ScheduledAction,
        contact: contact,
        conversation: nil,
        payload: { 'attachments' => [{ 'signed_id' => 'sid-1', 'file_type' => 'image', 'name' => 'a.png' }] }
      )
    end
    let(:message) { instance_double(Message) }
    let(:message_attachments) { instance_double(ActiveRecord::AssociationRelation) }

    it 'builds message attachments from the stored signed ids' do
      allow(ActiveStorage::Blob).to receive(:find_signed).with('sid-1').and_return(file_blob)
      allow(message).to receive(:attachments).and_return(message_attachments)
      expect(message_attachments).to receive(:build).with(
        file: file_blob,
        file_type: 'image',
        fallback_title: 'a.png',
        extension: 'png',
        meta: nil
      )

      service.send(:attach_scheduled_files, message)
    end

    it 'skips entries whose blob cannot be resolved' do
      allow(ActiveStorage::Blob).to receive(:find_signed).with('sid-1').and_return(nil)
      allow(message).to receive(:attachments).and_return(message_attachments)
      expect(message_attachments).not_to receive(:build)

      service.send(:attach_scheduled_files, message)
    end
  end
end

