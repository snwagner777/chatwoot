module SsoAuthenticatable
  extend ActiveSupport::Concern

  def generate_sso_auth_token(impersonation: false, eps_session: nil)
    token = SecureRandom.hex(32)
    value = if eps_session
              { eps_session: eps_session }.to_json
            else
              impersonation ? 'impersonation' : 'normal'
            end
    ::Redis::Alfred.setex(sso_token_key(token), value, 5.minutes)
    token
  end

  def invalidate_sso_auth_token(token)
    ::Redis::Alfred.delete(sso_token_key(token))
  end

  def valid_sso_auth_token?(token)
    ::Redis::Alfred.get(sso_token_key(token)).present?
  end

  def generate_sso_link(eps_session: nil)
    encoded_email = ERB::Util.url_encode(email)
    "#{ENV.fetch('FRONTEND_URL', nil)}/app/login?email=#{encoded_email}&sso_auth_token=#{generate_sso_auth_token(eps_session: eps_session)}"
  end

  def eps_sso_session(token)
    JSON.parse(::Redis::Alfred.get(sso_token_key(token)).to_s)['eps_session']
  rescue JSON::ParserError
    nil
  end

  def sso_auth_token_impersonation?(token)
    ::Redis::Alfred.get(sso_token_key(token)) == 'impersonation'
  end

  def generate_sso_link_with_impersonation
    encoded_email = ERB::Util.url_encode(email)
    "#{ENV.fetch('FRONTEND_URL',
                 nil)}/app/login?email=#{encoded_email}&sso_auth_token=#{generate_sso_auth_token(impersonation: true)}&impersonation=true"
  end

  private

  def sso_token_key(token)
    format(::Redis::RedisKeys::USER_SSO_AUTH_TOKEN, user_id: id, token: token)
  end
end
