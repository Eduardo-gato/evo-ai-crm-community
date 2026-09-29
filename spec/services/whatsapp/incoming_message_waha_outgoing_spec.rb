# frozen_string_literal: true

require 'rails_helper'

# WAHA mirrors Evolution/Evolution Go by surfacing messages sent from the paired
# phone (`fromMe`) as outgoing messages on the EXISTING contact/conversation.
RSpec.describe Whatsapp::IncomingMessageWahaService do
  subject(:service) { described_class.new(inbox: inbox, params: params) }

  let(:session) { "echo-#{SecureRandom.hex(4)}" }
  let(:channel) do
    Channel::Whatsapp.new(
      provider: 'waha',
      provider_config: {
        'api_url' => 'http://waha.test',
        'api_key' => 'secret',
        'session' => session
      }
    ).tap { |record| record.save!(validate: false) }
  end
  let(:inbox) { Inbox.create!(channel: channel, name: "WAHA #{SecureRandom.hex(3)}") }
  let(:contact) { Contact.create!(name: 'Ana', phone_number: '+5511999999999') }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: '5511999999999') }
  let!(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :pending)
  end

  let(:params) do
    {
      event: 'message.any',
      payload: {
        id: 'true_5511999999999@c.us_ECHO',
        fromMe: true,
        body: 'Enviada pelo aparelho',
        timestamp: 1_700_000_000_000,
        ackName: 'DEVICE',
        _data: { Info: { Chat: '5511999999999@c.us', RecipientAlt: '5511999999999@s.whatsapp.net' } }
      }
    }
  end

  it 'stores the echo as an outgoing message on the existing conversation' do
    service.perform

    message = conversation.messages.last
    expect(message).to be_present
    expect(message.message_type).to eq('outgoing')
    expect(message.content).to eq('Enviada pelo aparelho')
    expect(message.source_id).to eq('true_5511999999999@c.us_ECHO')
  end

  it 'does not create a new contact' do
    expect { service.perform }.not_to change(Contact, :count)
  end

  it 'matches the phone JID even with a device suffix' do
    params[:payload][:_data][:Info][:RecipientAlt] = '5511999999999:92@s.whatsapp.net'
    before_count = Contact.count

    expect { service.perform }.to change { conversation.messages.count }.by(1)
    expect(Contact.count).to eq(before_count)
  end

  it 'opens a pending conversation' do
    service.perform

    expect(conversation.reload.status).to eq('open')
  end

  it 'preserves the document name and extension on an echoed file' do
    params[:payload][:body] = ''
    params[:payload][:hasMedia] = true
    params[:payload][:media] = {
      url: 'http://waha.test/api/files/doc-1',
      mimetype: 'application/pdf',
      filename: 'contrato.pdf'
    }
    allow(service).to receive(:download_attachment_file).and_return(StringIO.new('pdf-bytes'))

    service.perform

    attachment = conversation.messages.last.attachments.last
    expect(attachment).to be_present
    expect(attachment.file_type).to eq('file')
    expect(attachment.fallback_title).to eq('contrato.pdf')
    expect(attachment.extension).to eq('pdf')
  end

  it 'deduplicates the echo of a message already stored (same source_id)' do
    existing = conversation.messages.create!(
      inbox_id: inbox.id,
      content: 'do painel',
      source_id: 'true_5511999999999@c.us_ECHO',
      message_type: :outgoing,
      status: :sent
    )

    expect { service.perform }.not_to change(Message, :count)
    expect(existing.reload.status).to eq('delivered')
  end

  it 'ignores the echo when there is no matching contact/conversation' do
    params[:payload][:_data][:Info][:Chat] = '5599999999999@c.us'
    params[:payload][:_data][:Info][:RecipientAlt] = '5599999999999@s.whatsapp.net'

    expect { service.perform }.not_to change(Message, :count)
  end
end
