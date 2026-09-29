class Whatsapp::IncomingMessageWahaService < Whatsapp::IncomingMessageBaseService
  def perform
    case event_name
    when 'message.any', 'message'
      if outgoing_echo?
        process_outgoing_echo
      else
        return if broadcast_or_status?(payload[:from])

        @processed_params = normalize_message
        super
      end
    when 'message.ack'
      process_ack
    when 'session.status'
      process_session_status
    when 'message.revoked'
      mark_message_revoked_by_source_id(payload[:revoked_message_id] || payload[:revokedMessageId] || payload.dig(:after, :id))
    when 'message.edited'
      process_edited_message
    else
      Rails.logger.debug "WAHA event ignored: #{event_name}"
    end
  end

  private

  def event_payload
    @event_payload ||= params.to_h.deep_symbolize_keys
  end

  def event_name
    event_payload[:event].to_s
  end

  def payload
    event_payload[:payload].is_a?(Hash) ? event_payload[:payload] : {}
  end

  def normalize_message
    from = resolved_from
    media = payload[:media].is_a?(Hash) ? payload[:media] : {}
    type = media.present? || payload[:has_media] || payload[:hasMedia] ? media_type(media) : 'text'
    reply_id = payload.dig(:reply_to, :id) || payload.dig(:replyTo, :id)
    normalized = {
      messages: [{
        id: payload[:id].to_s,
        from: from,
        type: type,
        text: { body: payload[:body].to_s },
        context: { id: reply_id, 'id' => reply_id }
      }],
      contacts: [{
        wa_id: from,
        profile: { name: payload[:notifyName] || payload[:push_name] || payload[:pushName] || payload.dig(:_data, :notifyName) }
      }]
    }
    normalized[:messages].first[type.to_sym] = media_payload(media, payload[:body]) if type != 'text'
    normalized
  end

  def media_type(media)
    mimetype = media_mimetype(media)
    return 'image' if mimetype.start_with?('image/')
    return 'audio' if mimetype.start_with?('audio/')
    return 'video' if mimetype.start_with?('video/')

    'document'
  end

  # WAHA exposes the mimetype on `media`, but some engines/paths omit it (or
  # deliver `media.url = null`). Fall back to the raw engine message so we still
  # render the correct preview (image/video/audio) instead of a generic file.
  def media_mimetype(media)
    media[:mimetype].presence || media[:mimeType].presence || data_message_mimetype.to_s
  end

  def media_payload(media, caption)
    {
      id: media[:url].presence || payload[:id].to_s,
      caption: caption.to_s,
      filename: media_filename(media),
      mimetype: media_mimetype(media).presence
    }
  end

  # `media.filename` carries the original document name; fall back to the raw
  # engine message for engines that only expose `fileName` there.
  def media_filename(media)
    media[:filename].presence || media[:fileName].presence || media[:file_name].presence || data_message_filename
  end

  MEDIA_MESSAGE_KEYS = %i[imageMessage videoMessage audioMessage documentMessage stickerMessage].freeze
  MIMETYPE_EXTENSIONS = {
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    'video/mp4' => 'mp4',
    'video/3gpp' => '3gp',
    'audio/ogg' => 'ogg',
    'audio/mpeg' => 'mp3',
    'audio/mp4' => 'm4a',
    'application/pdf' => 'pdf'
  }.freeze

  def data_message_mimetype
    message = data_media_message
    MEDIA_MESSAGE_KEYS.each do |key|
      value = message.dig(key, :mimetype)
      return value if value.present?
    end
    nil
  end

  def data_message_filename
    message = data_media_message
    message.dig(:documentMessage, :fileName).presence || message.dig(:documentMessage, :filename).presence
  end

  # The raw engine payload keeps the protocol message under `_data.message`,
  # sometimes wrapped (documentWithCaption / viewOnce / ephemeral).
  def data_media_message
    raw = payload[:_data]
    return {} unless raw.is_a?(Hash)

    message = raw[:message] || raw[:Message]
    return {} unless message.is_a?(Hash)

    inner = message.dig(:documentWithCaptionMessage, :message) ||
            message.dig(:viewOnceMessage, :message) ||
            message.dig(:viewOnceMessageV2, :message) ||
            message.dig(:ephemeralMessage, :message)
    inner.is_a?(Hash) ? message.merge(inner) : message
  end

  def media_extension(name, media)
    from_name = name.present? ? File.extname(name).delete_prefix('.') : nil
    return from_name if from_name.present?

    mimetype = media_mimetype(media).to_s.split(';').first
    return nil if mimetype.blank?

    MIMETYPE_EXTENSIONS.fetch(mimetype) { mimetype.split('/').last }
  end

  # The shared base service ignores WAHA's filename/mimetype, so attachments
  # showed up as a generic "Arquivo" without extension or preview. Override it to
  # persist `fallback_title`/`extension` and use the real content type.
  def attach_files
    return if %w[text button interactive location contacts].include?(message_type)

    attachment_payload = @processed_params[:messages].first[message_type.to_sym]
    @message.content ||= attachment_payload[:caption]

    attachment_file = download_attachment_file(attachment_payload)
    return if attachment_file.blank?

    build_media_attachment(@message, file_content_type(message_type), attachment_payload, attachment_file)
  end

  def build_media_attachment(message, file_type, attachment_payload, attachment_file)
    media = payload[:media].is_a?(Hash) ? payload[:media] : {}
    name = attachment_payload[:filename].presence
    content_type = attachment_payload[:mimetype].presence || attachment_file.content_type

    attachment = message.attachments.new(
      file_type: file_type,
      fallback_title: name,
      file: {
        io: attachment_file,
        filename: name.presence || attachment_file.original_filename,
        content_type: content_type
      }
    )
    extension = media_extension(name, media)
    attachment.extension = extension if extension.present?
    attachment
  end

  def set_contact
    source_id = contact_source_id(resolved_from)
    return if source_id.blank?

    phone_number = source_id.match?(/\A\d{8,15}\z/) ? "+#{source_id}" : nil
    name = contact_name(source_id, phone_number)
    @contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: { name: name, phone_number: phone_number }
    ).perform
    @contact = @contact_inbox.contact
    improve_contact_name(name)
  end

  def conversation_params
    super.merge(additional_attributes: { waha_chat_id: normalized_jid(resolved_from) })
  end

  def process_ack
    message = inbox.messages.find_by(source_id: payload[:id].to_s)
    return unless message

    status = {
      'SERVER' => 'sent',
      'DEVICE' => 'delivered',
      'READ' => 'read',
      'PLAYED' => 'read',
      'ERROR' => 'failed'
    }[(payload[:ack_name] || payload[:ackName]).to_s.upcase]
    return if status.blank?

    error = status == 'failed' ? 'WAHA reported a delivery error' : nil
    Messages::StatusUpdateService.new(message, status, error).perform
  end

  def process_session_status
    status = payload[:status].to_s.upcase
    channel = inbox.channel

    case status
    when 'WORKING'
      channel.mark_connected!
      sync_connected_phone(channel)
    when 'STARTING', 'SCAN_QR_CODE', 'PASSKEY_REQUIRED', 'PASSKEY_CONFIRMATION_REQUIRED'
      channel.update_provider_connection!('connection' => 'connecting', 'error' => nil)
    when 'FAILED'
      channel.prompt_reauthorization!
      channel.update_provider_connection!('connection' => 'disconnected', 'error' => 'WAHA session failed')
    when 'STOPPED'
      channel.update_provider_connection!('connection' => 'close', 'error' => 'WAHA session stopped')
    end
  rescue StandardError => e
    Rails.logger.error "WAHA session status failed: #{e.class} - #{e.message}"
  end

  def sync_connected_phone(channel)
    service = channel.provider_service
    service.sync_connected_phone! if service.respond_to?(:sync_connected_phone!)
  end

  def process_edited_message
    source_id = payload[:edited_message_id].presence || payload[:editedMessageId]
    message = inbox.messages.find_by(source_id: source_id.to_s)
    message&.update!(content: payload[:body].to_s)
  end

  def normalized_jid(value)
    jid = value.to_s.delete_prefix('+')
    return jid.sub('@s.whatsapp.net', '@c.us') if jid.end_with?('@s.whatsapp.net')

    jid
  end

  # `ContactInbox#source_id` must match WHATSAPP_CHANNEL_REGEX, which accepts
  # digits, `@lid`, `@g.us` and BSUIDs — but NOT `@c.us`. WAHA delivers 1:1
  # senders as `<number>@c.us`, so strip the suffix to the bare number and keep
  # the JID only for `waha_chat_id` (used when sending).
  def contact_source_id(value)
    jid = value.to_s.delete_prefix('+')
    return if broadcast_or_status?(jid)
    return jid.split('@').first.split(':').first if jid.end_with?('@c.us', '@s.whatsapp.net')

    jid
  end

  def broadcast_or_status?(value)
    jid = value.to_s
    jid.blank? || jid.include?('@broadcast')
  end

  # WAHA reports the sender's WhatsApp name in `notifyName` (usually under
  # `_data`). Prefer it over the raw JID so contacts show a name instead of
  # `<digits>@lid`.
  def contact_name(source_id, phone_number)
    payload[:notifyName].presence ||
      payload[:pushName].presence ||
      payload[:push_name].presence ||
      payload.dig(:_data, :notifyName).presence ||
      phone_number ||
      source_id
  end

  # ContactInboxWithContactBuilder reuses an existing contact without refreshing
  # its name, so a contact first seen as a `@lid` keeps that JID as its name.
  # Replace only placeholder names (blank, the raw source_id or a phone number),
  # never a name a user may have curated.
  def improve_contact_name(name)
    return if name.blank? || @contact.blank? || @contact.name == name

    placeholder = @contact.name.blank? ||
                  @contact.name == source_id_for_contact ||
                  @contact.name.match?(/\A\+?\d+\z/)
    return unless placeholder

    @contact.update!(name: name)
  rescue StandardError => e
    Rails.logger.warn "WAHA contact name update failed: #{e.class} - #{e.message}"
  end

  def source_id_for_contact
    @contact_inbox&.source_id || contact_source_id(resolved_from)
  end

  # WhatsApp delivers some 1:1 senders with a `@lid` (privacy identifier) instead
  # of the phone JID. Resolve it to the phone (`@c.us`) so the message lands on
  # the phone-based contact/conversation instead of creating a separate one.
  def resolved_from
    @resolved_from ||= begin
      from = payload[:from].to_s
      if from.end_with?('@lid')
        alternative_phone_jid(from) || lid_phone_jid(from) || from
      else
        from
      end
    end
  end

  # Some engines include the phone JID alongside the LID in the raw payload.
  def alternative_phone_jid(_lid)
    candidates = [
      payload.dig(:_data, :Info, :SenderAlt),
      payload.dig(:_data, :Info, :RecipientAlt),
      payload.dig(:_data, :Info, :senderAlt),
      payload.dig(:_data, :key, :remoteJidAlt),
      payload.dig(:_data, :key, :participantAlt),
      payload[:sender_alt],
      payload[:senderAlt],
      payload[:participantAlt]
    ]
    candidates.each do |candidate|
      jid = normalize_phone_jid(candidate)
      return jid if jid.present?
    end
    nil
  end

  # `SenderAlt` may arrive with a device suffix (`5562...:92@s.whatsapp.net`);
  # strip it so the resulting JID matches the phone-based contact/source_id.
  def normalize_phone_jid(value)
    jid = value.to_s.strip
    return nil if jid.blank? || jid.end_with?('@lid')

    jid = jid.sub(/:(\d+)@/, '@')
    return nil unless jid.end_with?('@c.us', '@s.whatsapp.net')

    jid
  end

  # WAHA emits an echo for messages sent from the paired phone (`fromMe`). The
  # other WhatsApp providers (Evolution / Evolution Go) surface those as outgoing
  # messages, so we mirror that behaviour: attach the echo to the EXISTING
  # contact/conversation (matched by phone / stored waha_chat_id) and store it as
  # outgoing. Never creates a new contact, and skips when a message with the same
  # source_id already exists (the echo of a message sent from the CRM panel).
  def process_outgoing_echo
    source_id = payload[:id].to_s
    return if source_id.blank? || broadcast_or_status?(peer_chat_id)

    existing = inbox.messages.find_by(source_id: source_id)
    if existing
      update_echo_delivery(existing)
      return
    end

    contact_inbox = outgoing_contact_inbox
    if contact_inbox.blank?
      Rails.logger.info "WAHA outgoing echo: no existing contact (chat=#{peer_chat_id} phone=#{peer_phone}); skipping"
      return
    end

    conversation = contact_inbox.conversations.where.not(status: :resolved).last ||
                   contact_inbox.conversations.last
    return if conversation.blank?

    media = payload[:media].is_a?(Hash) ? payload[:media] : {}
    type = media.present? || payload[:has_media] || payload[:hasMedia] ? media_type(media) : 'text'

    message = conversation.messages.build(
      inbox_id: inbox.id,
      content: payload[:body].to_s,
      source_id: source_id,
      message_type: :outgoing,
      sender: outgoing_echo_sender,
      sender_type: 'User',
      created_at: echo_created_at
    )

    attach_echo_media(message, type, media) if type != 'text'

    message.save!
    conversation.update!(status: :open) if conversation.status == 'pending'
  rescue StandardError => e
    Rails.logger.error "WAHA outgoing echo failed: #{e.class} - #{e.message}"
  end

  def attach_echo_media(message, type, media)
    attachment_payload = media_payload(media, payload[:body])
    message.content = attachment_payload[:caption] if message.content.blank?
    attachment_file = download_attachment_file(attachment_payload)
    return if attachment_file.blank?

    build_media_attachment(message, file_content_type(type), attachment_payload, attachment_file)
  end

  # The echo of a message we already stored (sent from the CRM) is not duplicated;
  # only its delivery status is refreshed here.
  def update_echo_delivery(message)
    ack = (payload[:ack_name] || payload[:ackName]).to_s.upcase
    status = {
      'SERVER' => 'sent',
      'DEVICE' => 'delivered',
      'READ' => 'read',
      'PLAYED' => 'read',
      'ERROR' => 'failed'
    }[ack]
    return if status.blank? || message.status == status

    Messages::StatusUpdateService.new(message, status, nil).perform
  end

  def outgoing_echo?
    payload[:from_me] == true || payload[:fromMe] == true
  end

  # Peer (contact) chat id reported by WAHA under `_data.Info.Chat`.
  def peer_chat_id
    payload.dig(:_data, :Info, :Chat).presence ||
      payload[:chat_id].presence ||
      payload[:chatId].presence
  end

  # Peer (contact) phone for a `fromMe` message: `_data.Info.RecipientAlt`.
  def peer_phone
    value = payload.dig(:_data, :Info, :RecipientAlt).presence ||
            payload[:recipient_alt].presence ||
            payload[:recipientAlt].presence
    normalize_phone_jid(value)&.split('@')&.first
  end

  def outgoing_contact_inbox
    phone = peer_phone
    if phone.present?
      contact_inbox = inbox.contact_inboxes.find_by(source_id: phone) ||
                      inbox.contact_inboxes.joins(:contact).find_by(contacts: { phone_number: "+#{phone}" }) ||
                      inbox.contact_inboxes.joins(:contact).find_by(contacts: { identifier: "#{phone}@c.us" })
      return contact_inbox if contact_inbox.present?
    end

    chat_id = peer_chat_id
    return if chat_id.blank?

    conversation = inbox.conversations.where("additional_attributes ->> 'waha_chat_id' = ?", chat_id).first
    conversation&.contact_inbox
  end

  def outgoing_echo_sender
    User.where(type: 'SuperAdmin').first || User.first
  end

  def echo_created_at
    ms = payload[:timestamp].to_i
    ms.positive? ? Time.zone.at(ms / 1000.0) : Time.current
  end

  def lid_phone_jid(lid)
    cache_key = "waha:lid:#{inbox.channel.provider_config['session']}:#{lid}"
    cached = Rails.cache.read(cache_key)
    return cached if cached.present?

    service = inbox.channel.provider_service
    return nil unless service.respond_to?(:resolve_lid)

    phone = service.resolve_lid(lid)
    return nil if phone.blank?

    jid = "#{phone}@c.us"
    Rails.cache.write(cache_key, jid, expires_in: 12.hours)
    jid
  end
end
