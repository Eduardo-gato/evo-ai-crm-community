class Api::V1::Waha::SettingsController < Api::V1::BaseController
  require_permissions({ update: 'inboxes.update' })

  # Updates the WAHA connection overrides for an existing channel. The generic
  # inbox update replaces provider_config wholesale, which would wipe session,
  # engine, ignore flags and the webhook HMAC — so this endpoint merges only the
  # connection keys. The API key is never returned.
  def update
    channel = find_waha_channel
    return render json: { error: 'WAHA session not found' }, status: :not_found if channel.blank?

    config = channel.provider_config.to_h.deep_dup
    if ActiveModel::Type::Boolean.new.cast(params[:use_global])
      config.delete('api_url')
      config.delete('api_key')
    else
      api_url = params[:api_url].to_s.strip
      return render json: { error: 'WAHA URL is required' }, status: :unprocessable_entity if api_url.blank?

      config['api_url'] = api_url
      # A blank API key means "keep the current one".
      api_key = params[:api_key].to_s.strip
      config['api_key'] = api_key if api_key.present?
    end

    channel.update!(provider_config: config)
    reapply_webhook(channel)

    render json: { success: true, provider_config: sanitized_config(channel) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "WAHA settings update failed: #{e.class} - #{e.message}"
    render json: { error: 'WAHA settings update failed' }, status: :unprocessable_entity
  end

  private

  # Editing the connection (URL/API key) may point the channel at a server whose
  # session lost the CRM webhook; (re)apply it best-effort so events keep coming.
  def reapply_webhook(channel)
    service = channel.provider_service
    return unless service.respond_to?(:apply_session_config!)

    config = channel.provider_config.to_h
    service.apply_session_config!(
      ignore: {
        groups: config['ignore_groups'],
        status: config['ignore_status'],
        channels: config['ignore_channels'],
        broadcast: config['ignore_broadcast']
      }
    )
  rescue StandardError => e
    Rails.logger.warn "WAHA settings: webhook reapply failed: #{e.class} - #{e.message}"
  end

  def find_waha_channel
    identifier = params[:session].presence || params[:session_name].presence || params[:id].presence
    return nil if identifier.blank?

    Channel::Whatsapp.joins(:inbox).where(provider: 'waha').find do |candidate|
      candidate.provider_config['session'].to_s == identifier.to_s ||
        candidate.provider_config['session_name'].to_s == identifier.to_s
    end
  end

  def sanitized_config(channel)
    config = channel.provider_config.to_h.deep_dup
    config.delete('api_key')
    config.delete('webhook_hmac_key')
    config['api_key_configured'] = channel.provider_config['api_key'].present? ||
                                   GlobalConfigService.load('WAHA_API_KEY', '').to_s.present?
    config
  end
end
