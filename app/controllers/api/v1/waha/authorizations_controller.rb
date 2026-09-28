require 'cgi'

class Api::V1::Waha::AuthorizationsController < Api::V1::BaseController
  require_permissions({
    create: 'inboxes.create',
    connect: 'inboxes.update',
    fetch: 'inboxes.read',
    logout: 'inboxes.update',
    delete_session: 'inboxes.delete',
    sync_webhook: 'inboxes.update'
  })

  def create
    unless waha_enabled?
      return render json: { error: 'WAHA provider is disabled' }, status: :forbidden
    end

    data = params[:authorization] || params
    api_url = Whatsapp::Providers::WahaService.normalize_api_url(
      data[:api_url].presence || GlobalConfigService.load('WAHA_API_URL', '').to_s.strip
    )
    api_key = data[:api_key].presence || GlobalConfigService.load('WAHA_API_KEY', '').to_s.strip
    session_name = data[:session].presence || data[:session_name].presence || generated_session_name(data[:name])
    Rails.logger.info "WAHA authorization: session=#{session_name} engine=#{data[:engine].presence || 'GOWS'} mode=#{data[:mode].presence || 'create'}"

    return render_missing(api_url, api_key, session_name) if [api_url, api_key, session_name].any?(&:blank?)

    if data[:mode].to_s == 'test'
      response = waha_request(:get, api_url, '/api/sessions', api_key: api_key)
      return render_external_error(response) unless response.success?

      return render json: { success: true, message: 'WAHA connection verified successfully' }
    end

    configured_hmac_key = GlobalConfigService.load('WAHA_WEBHOOK_HMAC_KEY', '').to_s.strip.presence
    webhook_hmac_key = data[:webhook_hmac_key].presence || configured_hmac_key || SecureRandom.hex(32)
    generated_hmac_key = configured_hmac_key.blank? && data[:webhook_hmac_key].blank?
    webhook_url = Whatsapp::Providers::WahaService.webhook_url
    return render json: { error: 'BACKEND_URL or WAHA_WEBHOOK_BASE_URL is required' }, status: :unprocessable_entity if webhook_url.start_with?('/')

    config = Whatsapp::Providers::WahaService.session_config(
      hmac_key: webhook_hmac_key,
      ignore: {
        groups: ActiveModel::Type::Boolean.new.cast(data[:ignore_groups]),
        status: ActiveModel::Type::Boolean.new.cast(data[:ignore_status]),
        channels: ActiveModel::Type::Boolean.new.cast(data[:ignore_channels]),
        broadcast: ActiveModel::Type::Boolean.new.cast(data[:ignore_broadcast])
      }
    )
    body = { name: session_name, config: config }
    body[:engine] = data[:engine].to_s.upcase if data[:engine].present?

    response = waha_request(:post, api_url, '/api/sessions', api_key: api_key, body: body)
    reused = false
    unless response.success?
      if session_exists_error?(response)
        # A session with this name already exists: push the (new) config via PUT
        # so channel creation is idempotent instead of failing.
        response = waha_request(:put, api_url, "/api/sessions/#{CGI.escape(session_name)}", api_key: api_key, body: body)
        return render_external_error(response) unless response.success?

        reused = true
      elsif session_forbidden?(response)
        # A session-scoped API key (scope "Session") cannot create sessions. If
        # the session already exists, reference it and try to (re)apply the CRM
        # webhook config (best effort: the key may not allow PUT either).
        existing = waha_request(:get, api_url, "/api/sessions/#{CGI.escape(session_name)}", api_key: api_key)
        return render_external_error(response) unless existing.success?

        reuse_response = waha_request(:put, api_url, "/api/sessions/#{CGI.escape(session_name)}", api_key: api_key, body: body)
        unless reuse_response.success?
          Rails.logger.warn "WAHA reuse: could not apply session config for #{session_name} (#{reuse_response.code})"
        end
        reused = true
      else
        return render_external_error(response)
      end
    end

    render json: {
      success: true,
      session: session_name,
      api_url: api_url,
      engine: data[:engine].to_s.upcase.presence || 'GOWS',
      webhook_hmac_key: generated_hmac_key ? webhook_hmac_key : nil,
      reused: reused,
      message: reused ? 'WAHA session reused' : 'WAHA session created successfully'
    }, status: :created
  rescue StandardError => e
    Rails.logger.error "WAHA authorization error: #{e.class} - #{e.message}"
    render json: { error: 'WAHA authorization failed' }, status: :unprocessable_entity
  end

  def connect
    with_session_request(:post, :start)
  end

  def fetch
    data = session_data
    response = waha_request(:get, data[:api_url], "/api/sessions/#{CGI.escape(data[:session])}", api_key: data[:api_key])
    return render_external_error(response) unless response.success?

    update_channel_connection(data[:channel], response.parsed_response)
    render json: { success: true, data: response.parsed_response }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def logout
    with_session_request(:post, :logout)
  end

  # Reapplies the CRM webhook (URL + HMAC + events) to an existing WAHA session.
  # Useful when the session was created outside the CRM or its webhooks were
  # cleared, so the operator can fix it from the channel settings.
  def sync_webhook
    data = session_data
    channel = data[:channel]
    return render json: { error: 'WAHA session not found' }, status: :not_found if channel.blank?

    service = channel.provider_service
    applied = service.respond_to?(:apply_session_config!) &&
              service.apply_session_config!(ignore: waha_ignore_flags(channel))

    if applied
      render json: { success: true, message: 'WAHA webhook reapplied' }
    else
      render json: { error: 'Não foi possível reaplicar o webhook na WAHA. Verifique a URL, a API key e as permissões.' },
             status: :unprocessable_entity
    end
  end

  def delete_session
    data = session_data
    response = waha_request(:delete, data[:api_url], "/api/sessions/#{CGI.escape(data[:session])}", api_key: data[:api_key])
    return render_external_error(response) unless response.success?

    render json: { success: true, message: 'WAHA session deleted successfully' }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def with_session_request(method, action)
    data = session_data
    response = waha_request(method, data[:api_url], "/api/sessions/#{CGI.escape(data[:session])}/#{action}", api_key: data[:api_key])
    return render_external_error(response) unless response.success?

    render json: { success: true, data: response.parsed_response }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def session_data
    identifier = params[:session].presence || params[:session_name].presence || params[:id].presence
    channel = Channel::Whatsapp.joins(:inbox)
                               .where(provider: 'waha')
                               .find do |candidate|
      candidate.provider_config['session'].to_s == identifier.to_s ||
        candidate.provider_config['session_name'].to_s == identifier.to_s
    end
    config = (channel&.provider_config || {}).to_h
    {
      channel: channel,
      api_url: Whatsapp::Providers::WahaService.normalize_api_url(
        config['api_url'].presence || params[:api_url].presence || GlobalConfigService.load('WAHA_API_URL', '').to_s.strip
      ),
      api_key: config['api_key'].presence || params[:api_key].presence || GlobalConfigService.load('WAHA_API_KEY', '').to_s.strip,
      session: config['session'].presence || config['session_name'].presence || identifier.to_s
    }
  end

  def update_channel_connection(channel, response_data)
    return unless channel

    status = (response_data['status'] || response_data.dig('data', 'status')).to_s.upcase
    if status == 'WORKING'
      channel.mark_connected!
      service = channel.provider_service
      service.sync_connected_phone! if service.respond_to?(:sync_connected_phone!)
    else
      channel.update_provider_connection!('connection' => 'close', 'error' => status.presence)
    end
  end

  def generated_session_name(name)
    # WAHA (Plus / current free build) supports multiple sessions, so each
    # channel gets its own session instead of sharing `default`. When the user
    # leaves the optional session field empty, derive a stable, unique name from
    # the channel name so QR/me/webhook routing stays per-channel.
    slug = name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '').presence || 'waha'
    "evo-#{slug.first(40)}-#{SecureRandom.hex(4)}"
  end

  def waha_request(method, api_url, path, api_key:, body: nil)
    base = Whatsapp::Providers::WahaService.normalize_api_url(api_url).chomp('/')
    HTTParty.public_send(
      method,
      "#{base}#{path}",
      headers: { 'X-Api-Key' => api_key, 'Content-Type' => 'application/json', 'Accept' => 'application/json' },
      body: body&.to_json,
      open_timeout: 10,
      read_timeout: 30
    )
  end

  def render_missing(api_url, api_key, session_name)
    missing = []
    missing << 'api_url' if api_url.blank?
    missing << 'api_key' if api_key.blank?
    missing << 'session' if session_name.blank?
    render json: { error: "Missing required parameters: #{missing.join(', ')}" }, status: :bad_request
  end

  def render_external_error(response)
    code = response.code.to_i
    Rails.logger.warn "WAHA external error #{code}: #{response.body.to_s.truncate(300)}"
    # Authentication/authorization failures are actionable by the operator, so
    # return 4xx with a clear message (5xx bodies are hidden by the frontend).
    if [401, 403].include?(code)
      return render json: { error: waha_auth_error_message(code) }, status: :unprocessable_entity
    end

    render json: { error: response.body.to_s.truncate(500) }, status: :bad_gateway
  end

  def waha_auth_error_message(code)
    if code == 401
      'WAHA recusou a autenticação (401). Verifique a URL e a API key.'
    else
      'WAHA recusou a operação (403). A API key precisa de escopo de administrador ("Any") para criar/gerenciar sessões.'
    end
  end

  def session_exists_error?(response)
    response.code.to_i == 422 && response.body.to_s.include?('already exists')
  end

  def session_forbidden?(response)
    response.code.to_i == 403
  end

  def waha_ignore_flags(channel)
    config = channel.provider_config.to_h
    {
      groups: config['ignore_groups'],
      status: config['ignore_status'],
      channels: config['ignore_channels'],
      broadcast: config['ignore_broadcast']
    }
  end

  def waha_enabled?
    value = ENV['WAHA_ENABLED']
    value.blank? || ActiveModel::Type::Boolean.new.cast(value)
  end
end
