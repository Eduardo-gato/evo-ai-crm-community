require 'cgi'

class Api::V1::Waha::QrcodesController < Api::V1::BaseController
  require_permissions({ show: 'inboxes.read', create: 'inboxes.update' })

  def show
    render_qrcode
  end

  def create
    render_qrcode
  end

  private

  def render_qrcode
    identifier = params[:id].presence || params[:session].presence || params[:session_name].presence
    channel = Channel::Whatsapp.joins(:inbox).where(provider: 'waha').find do |candidate|
      config = candidate.provider_config
      config['session'].to_s == identifier.to_s || config['session_name'].to_s == identifier.to_s
    end
    config = (channel&.provider_config || {}).to_h
    api_url = Whatsapp::Providers::WahaService.normalize_api_url(
      config['api_url'].presence || GlobalConfigService.load('WAHA_API_URL', '').to_s.strip
    )
    api_key = config['api_key'].presence || GlobalConfigService.load('WAHA_API_KEY', '').to_s.strip
    session = config['session'].presence || config['session_name'].to_s

    return render json: { error: 'WAHA session not found' }, status: :not_found if channel.blank? || api_url.blank? || api_key.blank? || session.blank?

    response = HTTParty.get(
      "#{api_url.chomp('/')}/api/#{CGI.escape(session)}/auth/qr",
      headers: { 'X-Api-Key' => api_key, 'Accept' => 'application/json' },
      open_timeout: 10,
      read_timeout: 30
    )
    return render json: { error: response.body.to_s.truncate(500) }, status: :bad_gateway unless response.success?

    parsed = response.parsed_response
    render json: { success: true, qrcode: parsed['data'] || parsed }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
