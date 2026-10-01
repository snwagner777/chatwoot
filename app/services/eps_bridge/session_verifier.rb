require 'net/http'
require 'openssl'
require 'base64'

class EpsBridge::SessionVerifier
  def self.application_url
    origin = URI.parse(ENV.fetch('EPS_CORE_ORIGIN', ''))
    return unless origin.is_a?(URI::HTTPS) && origin.host.present?
    return unless ['', '/'].include?(origin.path) && [origin.userinfo, origin.query, origin.fragment].all?(&:nil?)

    origin.to_s
  rescue URI::InvalidURIError
    nil
  end

  def initialize(user)
    @user = user
  end

  def managed?
    @user.custom_attributes.key?('eps_bridge')
  end

  def active_client?(client_id, account_id = nil)
    token = @user.tokens[client_id]
    return false unless token && token['expiry'].to_i > Time.current.to_i

    binding = token['eps_session']
    return false if account_id.present? && account_id.to_s != binding&.dig('account_id').to_s

    active?(binding)
  end

  def active?(binding)
    return false unless valid_binding?(binding)

    payload = encode({ purpose: 'session-status', timestamp: Time.current.to_i, coreUserId: identity['core_user_id'],
                       webSessionId: binding['web_session_id'], chatwootUserId: @user.id, accountId: identity['account_id'] })
    request = Net::HTTP::Post.new('/api/v1/core/inbox2/session-status')
    request['content-type'] = 'text/plain; charset=utf-8'
    request['x-eps-bridge-payload'] = payload
    request['x-eps-bridge-signature'] = signature(payload)
    request['accept'] = 'application/json'
    callback_active?(request)
  rescue StandardError
    false
  end

  def valid_proxy?(request)
    verified_proxy_purpose(request).present?
  end

  def verified_proxy_purpose(request)
    claims = verified_claims(request)
    return unless fresh_claims?(claims) && matching_identity?(claims) && matching_request?(claims, request)
    return if Redis::Alfred.set("eps_bridge:request:#{@user.id}:#{claims['nonce']}", 'used', nx: true, ex: 60).blank?

    claims['purpose']
  rescue StandardError
    nil
  end

  private

  def valid_binding?(binding)
    binding.is_a?(Hash) && binding['core_user_id'] == identity['core_user_id'] &&
      binding['account_id'] == identity['account_id'] && binding['web_session_id'].is_a?(String)
  end

  def core_origin
    origin = URI.parse(ENV.fetch('EPS_CORE_ORIGIN', ''))
    valid = origin.is_a?(URI::HTTPS) && origin.host.present? && origin.userinfo.nil? &&
            ['', '/'].include?(origin.path) && origin.query.nil? && origin.fragment.nil?
    raise ArgumentError, 'Invalid EPS Core origin' unless valid

    origin
  end

  def callback_active?(request)
    origin = core_origin
    active = false
    Net::HTTP.start(origin.host, origin.port, use_ssl: true, open_timeout: 3, read_timeout: 3) do |http|
      http.request(request) do |response|
        active = response.code == '200' && bounded_response(response)['active'] == true
      end
    end
    active
  end

  def bounded_response(response)
    body = +''
    response.read_body do |chunk|
      body << chunk
      raise ArgumentError, 'Response too large' if body.bytesize > 4096
    end
    JSON.parse(body)
  end

  def verified_claims(request)
    payload = request.headers['x-eps-bridge-payload']
    supplied = request.headers['x-eps-bridge-signature']
    return unless payload.is_a?(String) && payload.bytesize <= 4096 && supplied.to_s.match?(/\A[a-f0-9]{64}\z/)
    return unless ActiveSupport::SecurityUtils.secure_compare(signature(payload), supplied)

    JSON.parse(Base64.urlsafe_decode64(payload))
  end

  def fresh_claims?(claims)
    claims.is_a?(Hash) && %w[native-proxy provider-operation].include?(claims['purpose']) && claims['timestamp'].is_a?(Integer) &&
      (Time.current.to_i - claims['timestamp']).abs <= 30 && claims['nonce'].to_s.match?(/\A[a-zA-Z0-9-]{1,100}\z/)
  end

  def matching_identity?(claims)
    claims['coreUserId'] == identity['core_user_id'] && claims['chatwootUserId'] == @user.id && claims['accountId'] == identity['account_id']
  end

  def matching_request?(claims, request)
    claims['method'] == request.request_method && claims['path'] == request.fullpath &&
      claims['bodyHash'] == Digest::SHA256.hexdigest(request.raw_post)
  end

  def identity
    @user.custom_attributes.fetch('eps_bridge')
  end

  def encode(value)
    Base64.urlsafe_encode64(value.to_json, padding: false)
  end

  def signature(payload)
    platform_app = PlatformApp.find(identity.fetch('platform_app_id'))
    OpenSSL::HMAC.hexdigest('SHA256', platform_app.access_token.token, payload)
  end
end
