class Whatsapp::IncomingMessageWahaService < Whatsapp::IncomingMessageBaseService
  def perform
    case event_name
    when 'message.any', 'message'
      return if payload[:from_me] == true || payload[:fromMe] == true
      return if broadcast_or_status?(payload[:from])

      @processed_params = normalize_message
      super
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
    mimetype = media[:mimetype].to_s
    return 'image' if mimetype.start_with?('image/')
    return 'audio' if mimetype.start_with?('audio/')
    return 'video' if mimetype.start_with?('video/')

    'document'
  end

  def media_payload(media, caption)
    {
      id: media[:url].presence || payload[:id].to_s,
      caption: caption.to_s,
      filename: media[:filename],
      mimetype: media[:mimetype]
    }
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
