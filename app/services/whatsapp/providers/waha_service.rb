require 'cgi'
require 'uri'
require 'base64'

class Whatsapp::Providers::WahaService < Whatsapp::Providers::BaseService
  # Outbound media is sent inline (base64) so a WAHA server on another host can
  # deliver it without being able to reach the CRM's storage host. Larger files
  # fall back to a signed URL (which requires network reachability).
  MAX_INLINE_ATTACHMENT_BYTES = 16.megabytes

  # Accepts URLs typed without a scheme (e.g. `waha.example.com`) by defaulting
  # to HTTPS, so external WAHA servers don't silently fail on requests.
  def self.normalize_api_url(value)
    url = value.to_s.strip
    return url if url.blank? || url.match?(%r{\Ahttps?://}i)

    "https://#{url}"
  end

  # Public URL WAHA should POST events to. Prefers the explicit override, then
  # BACKEND_URL (must be reachable from the WAHA server, not just the CRM host).
  def self.webhook_url
    GlobalConfigService.load('WAHA_WEBHOOK_BASE_URL', '').to_s.strip.presence ||
      "#{ENV.fetch('BACKEND_URL', '').chomp('/')}/webhooks/whatsapp/waha"
  end

  # Session config the CRM applies on create/update so WAHA delivers events and
  # respects the channel's ignore flags.
  def self.session_config(hmac_key:, ignore: {})
    {
      webhooks: [{
        url: webhook_url,
        events: %w[message.any message.ack message.revoked message.edited session.status],
        hmac: { key: hmac_key },
        retries: { policy: 'exponential', delaySeconds: 2, attempts: 5 }
      }],
      ignore: {
        groups: ignore[:groups] || false,
        status: ignore[:status] || false,
        channels: ignore[:channels] || false,
        broadcast: ignore[:broadcast] || false
      }
    }
  end

  def send_message(phone_number, message)
    @message = message

    if message.attachments.present?
      send_attachment_messages(phone_number, message)
    elsif message.content_type.in?(%w[input_select cards])
      send_text_message(phone_number, message)
    elsif message.content.present?
      send_text_message(phone_number, message)
    else
      message.update!(is_unsupported: true)
      nil
    end
  end

  def send_template(phone_number, template_info)
    send_text_message(phone_number, template_text(template_info))
  end

  def sync_templates
    Rails.logger.debug 'WAHA does not expose Meta templates; templates remain CRM-managed'
  end

  def validate_provider_config?
    api_url.present? && api_key.present? && session_name.present?
  rescue StandardError => e
    Rails.logger.error "WAHA validation error: #{e.class} - #{e.message}"
    false
  end

  def setup_channel_provider
    true
  end

  def disconnect_channel_provider
    return false if api_url.blank? || session_name.blank?

    request(:delete, "/api/sessions/#{encoded_session_name}")
    true
  rescue StandardError => e
    Rails.logger.error "WAHA disconnect error: #{e.class} - #{e.message}"
    false
  end

  # WAHA discovers the paired phone number server-side. Read it from `/me`,
  # keep it on `provider_config['me']` (always) and backfill `phone_number`
  # when it is still blank and not taken by another channel. Called when the
  # session reaches WORKING (webhook and settings polling).
  def sync_connected_phone!
    return unless api_url.present? && api_key.present? && session_name.present?

    me = fetch_me
    return if me.blank?

    channel = whatsapp_channel
    config = channel.provider_config.to_h.deep_dup
    config['me'] = me.slice('id', 'pushName', 'lid', 'name')
    updates = { provider_config: config }

    phone = normalize_me_phone(me['id'])
    if phone.present? && channel.phone_number.blank?
      if Channel::Whatsapp.where(phone_number: phone).where.not(id: channel.id).exists?
        Rails.logger.warn "WAHA /me phone #{phone} already belongs to another channel; keeping it in provider_config only"
      else
        updates[:phone_number] = phone
      end
    end

    channel.update_columns(updates)
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.warn 'WAHA /me phone conflicts with an existing channel; keeping it in provider_config only'
  rescue StandardError => e
    Rails.logger.warn "WAHA sync_connected_phone failed: #{e.class} - #{e.message}"
  end

  # Resolves a `@lid` (WhatsApp privacy identifier) to its phone number (digits),
  # so inbound messages from LIDs can be unified with the phone-based contact.
  # Returns nil when the mapping is unknown.
  def resolve_lid(lid)
    value = lid.to_s.strip
    return nil if value.blank? || api_url.blank? || api_key.blank? || session_name.blank?

    response = request(:get, "/api/#{encoded_session_name}/lids/#{CGI.escape(value)}")
    return nil unless response.success?

    parsed = response.parsed_response
    pn = parsed.is_a?(Hash) ? parsed['pn'] : nil
    pn.to_s.split('@').first.presence
  rescue StandardError => e
    Rails.logger.warn "WAHA resolve_lid failed: #{e.class} - #{e.message}"
    nil
  end

  # (Re)applies the session config (webhook + ignore flags) to an existing WAHA
  # session. Best-effort: returns false instead of raising so callers can keep
  # going when the API key cannot update the session (e.g. session-scoped key).
  def apply_session_config!(ignore: {}, hmac_key: nil)
    return false if api_url.blank? || api_key.blank? || session_name.blank?

    key = hmac_key.presence ||
          provider_config['webhook_hmac_key'].presence ||
          GlobalConfigService.load('WAHA_WEBHOOK_HMAC_KEY', '').to_s.strip
    return false if key.blank?

    body = { name: session_name, config: self.class.session_config(hmac_key: key, ignore: ignore) }
    response = request(:put, "/api/sessions/#{encoded_session_name}", body: body)
    unless response.success?
      Rails.logger.warn "WAHA apply_session_config failed #{response.code}: #{response.body.to_s.truncate(200)}"
      return false
    end

    true
  rescue StandardError => e
    Rails.logger.warn "WAHA apply_session_config error: #{e.class} - #{e.message}"
    false
  end

  def media_url(media_id)
    value = media_id.to_s
    uri = begin
      URI.parse(value)
    rescue URI::InvalidURIError
      nil
    end
    # WAHA advertises media URLs on its own (often internal, e.g. localhost:3000)
    # host. Rebuild them against the configured api_url so the CRM can reach them.
    if uri&.absolute?
      path = uri.path.to_s
      path = "/api/files/#{CGI.escape(value)}" unless path.start_with?('/api/')
      query = uri.query.present? ? "?#{uri.query}" : ''
      "#{api_base_path}#{path}#{query}"
    elsif value.start_with?('/')
      "#{api_base_path}#{value}"
    else
      "#{api_base_path}/api/files/#{CGI.escape(value)}"
    end
  end

  def api_headers
    {
      'X-Api-Key' => api_key,
      'Content-Type' => 'application/json',
      'Accept' => 'application/json'
    }
  end

  def read_messages(phone_number, messages)
    body = {
      session: session_name,
      chatId: destination_for(phone_number)
    }
    ids = Array(messages).filter_map { |message| message.source_id.presence }
    body[:messageIds] = ids if ids.present?
    request(:post, '/api/sendSeen', body: body)
  rescue StandardError => e
    Rails.logger.warn "WAHA mark-as-read failed: #{e.class} - #{e.message}"
    nil
  end

  def toggle_typing_status(phone_number, typing_status)
    endpoint = typing_status ? '/startTyping' : '/stopTyping'
    request(:post, endpoint, body: { session: session_name, chatId: destination_for(phone_number) })
  rescue StandardError => e
    Rails.logger.warn "WAHA typing status failed: #{e.class} - #{e.message}"
    nil
  end

  def delete_message(message)
    return false if message.source_id.blank?

    chat_id = message.conversation&.additional_attributes&.dig('waha_chat_id')
    return false if chat_id.blank?

    response = request(
      :delete,
      "/api/#{encoded_session_name}/chats/#{CGI.escape(chat_id)}/messages/#{CGI.escape(message.source_id)}"
    )
    response.success?
  rescue StandardError => e
    Rails.logger.warn "WAHA delete message failed: #{e.class} - #{e.message}"
    false
  end

  private

  def send_text_message(phone_number, message)
    content = message.respond_to?(:content) ? message.content : message.to_s
    body = {
      session: session_name,
      chatId: destination_for(phone_number),
      text: html_to_whatsapp(content.to_s)
    }
    add_reply_to(body, message)
    send_request('/api/sendText', body)
  end

  # WAHA sends one media per request, so a message with several attachments is
  # delivered as several requests. The text/caption rides the first one.
  def send_attachment_messages(phone_number, message)
    first_id = nil
    message.attachments.each_with_index do |attachment, index|
      id = send_attachment_message(phone_number, message, attachment, with_caption: index.zero?)
      first_id ||= id
    end
    first_id
  end

  def send_attachment_message(phone_number, message, attachment, with_caption:)
    endpoint, media_type = case attachment.file_type
                           when 'image' then ['/api/sendImage', 'image']
                           when 'audio' then ['/api/sendVoice', 'audio']
                           when 'video' then ['/api/sendVideo', 'video']
                           else ['/api/sendFile', 'document']
                           end

    blob = attachment.file.blob
    file = {
      mimetype: attachment.file.content_type.to_s,
      filename: attachment.file.filename.to_s
    }
    if blob.byte_size.to_i.positive? && blob.byte_size <= MAX_INLINE_ATTACHMENT_BYTES
      file[:data] = Base64.strict_encode64(attachment.file.download)
    else
      file[:url] = BlobUrlOptions.outbound_media_url(blob)
    end
    body = {
      session: session_name,
      chatId: destination_for(phone_number),
      file: file
    }
    body[:caption] = html_to_whatsapp(message.content.to_s) if with_caption && message.content.present?
    body[:convert] = true if media_type == 'audio'
    add_reply_to(body, message) if with_caption
    send_request(endpoint, body)
  end

  def send_request(endpoint, body)
    response = request(:post, endpoint, body: body)
    return response_id(response) if response.success?

    @last_delivery_error = response_body(response)
    false
  rescue StandardError => e
    @last_delivery_error = e.message.to_s.truncate(300)
    Rails.logger.error "WAHA send failed: #{e.class} - #{e.message}"
    false
  end

  def request(method, endpoint, body: nil)
    HTTParty.public_send(
      method,
      "#{api_base_path}#{endpoint}",
      headers: api_headers,
      body: body&.to_json,
      open_timeout: 10,
      read_timeout: 60
    )
  end

  def fetch_me
    response = request(:get, "/api/sessions/#{encoded_session_name}/me")
    return nil unless response.success?

    parsed = response.parsed_response
    parsed.is_a?(Hash) ? parsed : nil
  rescue StandardError => e
    Rails.logger.warn "WAHA /me failed: #{e.class} - #{e.message}"
    nil
  end

  def normalize_me_phone(value)
    digits = value.to_s.split('@').first.to_s.gsub(/\D/, '')
    return nil if digits.blank?

    "+#{digits}"
  end

  def response_id(response)
    parsed = response.parsed_response
    return true unless parsed.is_a?(Hash)

    # WAHA echoes the message-key object under `id` (and `_data.id`). Prefer the
    # serialized id because that is what WAHA sends back in message.any/ack, so
    # the CRM can correlate receipts with the message we stored.
    key = parsed['id'] || parsed.dig('data', 'id') || parsed['_data']&.dig('id')
    return key if key.is_a?(String) && key.present?
    return true unless key.is_a?(Hash)

    key['_serialized'].presence || key['id'].presence || true
  end

  def response_body(response)
    parsed = response.parsed_response
    return response.body.to_s.truncate(300) unless parsed.is_a?(Hash)

    parsed['message'].presence || parsed['error'].presence || response.body.to_s.truncate(300)
  end

  def add_reply_to(body, message)
    reply_to = message.content_attributes&.dig('in_reply_to_external_id')
    body[:reply_to] = reply_to if reply_to.present?
  end

  def destination_for(value)
    destination = value.to_s.delete_prefix('+')
    return destination if destination.include?('@g.us') || destination.include?('@lid') || destination.include?('@newsletter')
    return destination.sub('@s.whatsapp.net', '@c.us') if destination.end_with?('@s.whatsapp.net')
    return destination if destination.end_with?('@c.us')

    "#{destination}@c.us"
  end

  def template_text(info)
    text = info[:name].to_s.presence || 'Template Message'
    Array(info[:parameters]).each_with_index do |parameter, index|
      value = parameter.is_a?(Hash) ? parameter[:text] || parameter['text'] : parameter
      text = text.gsub("{{#{index + 1}}}", value.to_s)
    end
    text
  end

  def api_base_path
    api_url.to_s.chomp('/')
  end

  def api_url
    self.class.normalize_api_url(
      provider_config['api_url'].presence || GlobalConfigService.load('WAHA_API_URL', '').to_s.strip
    )
  end

  def api_key
    provider_config['api_key'].presence || GlobalConfigService.load('WAHA_API_KEY', '').to_s.strip
  end

  def session_name
    provider_config['session'].presence || provider_config['session_name'].presence
  end

  def provider_config
    whatsapp_channel.provider_config.to_h
  end

  def encoded_session_name
    CGI.escape(session_name.to_s)
  end
end
