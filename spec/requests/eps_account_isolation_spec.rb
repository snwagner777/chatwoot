require 'rails_helper'

RSpec.describe 'EPS account isolation', type: :request do
  let(:managed) { create(:account, custom_attributes: { eps_managed: true }) }
  let(:independent) { create(:account) }
  let(:platform_app) { create(:platform_app) }
  let(:user) do
    create(:user, :administrator, account: managed,
                                  custom_attributes: { eps_bridge: { platform_app_id: platform_app.id, core_user_id: 'eps-1',
                                                                     account_id: managed.id } })
  end
  let(:binding) { { 'core_user_id' => 'eps-1', 'web_session_id' => 'web-1', 'account_id' => managed.id } }
  let(:headers) { user.create_new_auth_token }

  before do
    create(:account_user, user: user, account: independent, role: :administrator, active_at: 1.day.ago)
    user.account_users.find_by!(account: managed).update!(active_at: Time.current)
  end

  it 'allows ordinary password login and lands only in the independent account without contacting Core' do
    post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, as: :json
    expect(response).to have_http_status(:ok)
    data = response.parsed_body.fetch('data')
    expect(data.fetch('accounts').pluck('id')).to eq([independent.id])
    expect(data.fetch('account_id')).to eq(independent.id)
    expect(data.fetch('custom_attributes', {})).not_to have_key('eps_bridge')
    expect(user.reload.tokens.dig(response.headers['client'], 'eps_session')).to be_nil
  end

  it 'keeps independent browser and API requests working through EPS outages and revocation' do
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      callback = stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_timeout
      get "/api/v1/accounts/#{independent.id}", headers: headers
      expect(response).to have_http_status(:ok)
      get "/api/v1/accounts/#{independent.id}", headers: { api_access_token: user.access_token.token }
      expect(response).to have_http_status(:ok)
      user.tokens[headers['client']]['eps_session'] = binding
      user.save!
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":false}')
      get "/api/v1/accounts/#{independent.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(callback).not_to have_been_requested
    end
  end

  it 'filters managed accounts and identity from profile and token-validation payloads' do
    get '/api/v1/profile', headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('accounts').pluck('id')).to eq([independent.id])
    expect(response.parsed_body.fetch('account_id')).to eq(independent.id)
    expect(response.parsed_body.fetch('custom_attributes', {})).not_to have_key('eps_bridge')
    get '/auth/validate_token', headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'data', 'accounts').pluck('id')).to eq([independent.id])
  end

  it 'hides revoked EPS account data while preserving a valid native session and independent memberships' do
    headers
    user.tokens[headers['client']]['eps_session'] = binding
    user.save!
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":false}')
      get '/api/v1/profile', headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch('accounts').pluck('id')).to eq([independent.id])
    end
  end

  it 'rejects native access to the managed account even for a member with no EPS identity' do
    native_user = create(:user, :administrator, account: managed)
    get "/api/v1/accounts/#{managed.id}", headers: native_user.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
    get "/api/v1/accounts/#{managed.id}", headers: { api_access_token: native_user.access_token.token }
    expect(response).to have_http_status(:unauthorized)
  end

  it 'protects nested profile account mutations without blocking independent availability' do
    post '/api/v1/profile/availability', params: { profile: { account_id: independent.id, availability: 'busy' } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(user.account_users.find_by!(account: independent).availability).to eq('busy')
    post '/api/v1/profile/availability', params: { profile: { account_id: managed.id, availability: 'busy' } }, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(user.account_users.find_by!(account: managed).availability).not_to eq('busy')
  end

  it 'still denies independent accounts without upstream membership' do
    other = create(:account)
    get "/api/v1/accounts/#{other.id}", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it 'allows other permitted PlatformApp SSO without creating an EPS session' do
    other_app = create(:platform_app)
    create(:platform_app_permissible, platform_app: other_app, permissible: user)
    get "/platform/api/v1/users/#{user.id}/login", headers: { api_access_token: other_app.access_token.token }
    expect(response).to have_http_status(:ok)
    token = Rack::Utils.parse_query(URI.parse(response.parsed_body.fetch('url')).query).fetch('sso_auth_token')
    post '/auth/sign_in', params: { email: user.email, sso_auth_token: token }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('data').fetch('accounts').pluck('id')).to eq([independent.id])
    expect(user.reload.tokens.dig(response.headers['client'], 'eps_session')).to be_nil
  end

  it 'does not downgrade malformed EPS token metadata into ordinary SSO' do
    token = user.generate_sso_auth_token(eps_session: {})
    post '/auth/sign_in', params: { email: user.email, sso_auth_token: token }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'cannot authorize a managed account using a decoy account parameter' do
    get "/api/v1/accounts/#{managed.id}?account_id=#{independent.id}", headers: headers
    expect(response).to have_http_status(:unauthorized)
    post '/api/v1/profile/auto_offline',
         params: { account_id: independent.id, profile: { account_id: managed.id, auto_offline: false } }, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    put '/api/v1/profile/set_active_account',
        params: { account_id: independent.id, profile: { account_id: managed.id } }, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'exposes only the matching managed membership for valid EPS sessions and rechecks membership' do
    another_managed = create(:account, custom_attributes: { eps_managed: true })
    create(:account_user, user: user, account: another_managed)
    headers
    user.tokens[headers['client']]['eps_session'] = binding
    user.save!
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":true}')
      get '/api/v1/profile', headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch('accounts').pluck('id')).to contain_exactly(managed.id, independent.id)
      get "/api/v1/accounts/#{another_managed.id}", headers: headers
      expect(response).to have_http_status(:unauthorized)
      user.account_users.find_by!(account: managed).destroy!
      expect(EpsBridge::SessionVerifier.new(user.reload).active_client?(headers['client'], managed.id)).to be(false)
      get "/api/v1/accounts/#{independent.id}", headers: headers
      expect(response).to have_http_status(:ok)
    end
  end

  it 'does not reuse an incoming EPS client when password login mints a native session' do
    headers
    user.tokens[headers['client']]['eps_session'] = binding
    user.save!
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      callback = stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":true}')
      post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'accounts').pluck('id')).to eq([independent.id])
      expect(callback).not_to have_been_requested
    end
  end

  it 'keeps MFA native authentication usable for the independent account' do
    user.enable_two_factor!
    user.update!(otp_required_for_login: true)
    post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, as: :json
    expect(response).to have_http_status(:partial_content)
    token = response.parsed_body.fetch('mfa_token')
    post '/auth/sign_in', params: { mfa_token: token, otp_code: user.current_otp }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'accounts').pluck('id')).to eq([independent.id])
  end

  it 'does not copy EPS authorization into a new account signup session' do
    headers
    user.tokens[headers['client']]['eps_session'] = binding
    user.save!
    allow(GlobalConfigService).to receive(:account_signup_enabled?).and_return(true)
    with_modified_env 'ENABLE_ACCOUNT_SIGNUP' => 'true', 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      callback = stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":true}')
      post '/api/v1/accounts', params: { account_name: 'New Independent Account', email: user.email, user_full_name: user.name },
                               headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      data = response.parsed_body.fetch('data')
      expect(data.fetch('accounts').pluck('id')).not_to include(managed.id)
      expect(data.fetch('account_id')).not_to eq(managed.id)
      expect(callback).not_to have_been_requested
    end
  end

  it 'rejects malformed stored EPS session metadata with unauthorized rather than an exception' do
    headers
    user.tokens[headers['client']]['eps_session'] = 'malformed'
    user.save!
    get "/api/v1/accounts/#{managed.id}", headers: headers
    expect(response).to have_http_status(:unauthorized)
  end

  it 'reserves identity binding changes against generic platform custom-attribute writes' do
    other_app = create(:platform_app)
    create(:platform_app_permissible, platform_app: other_app, permissible: user)
    original_identity = user.custom_attributes.fetch('eps_bridge')
    [nil, {}, { platform_app_id: other_app.id, account_id: managed.id, core_user_id: 'attacker' }].each do |replacement|
      patch "/platform/api/v1/users/#{user.id}", params: { custom_attributes: { eps_bridge: replacement } },
                                                 headers: { api_access_token: other_app.access_token.token }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload.custom_attributes.fetch('eps_bridge')).to eq(original_identity)
    end
    patch "/platform/api/v1/users/#{user.id}", params: { name: 'Independent profile', custom_attributes: { source: 'other-app' } },
                                               headers: { api_access_token: other_app.access_token.token }, as: :json
    expect(response).to have_http_status(:ok)
    expect(user.reload.custom_attributes).to include('eps_bridge' => original_identity, 'source' => 'other-app')
    expect(user.name).to eq('Independent profile')
    patch "/platform/api/v1/users/#{user.id}", params: { custom_attributes: {} },
                                               headers: { api_access_token: other_app.access_token.token }, as: :json
    expect(response).to have_http_status(:ok)
    expect(user.reload.custom_attributes.fetch('eps_bridge')).to eq(original_identity)
  end

  it 'does not let platform user creation preseed a forged EPS identity' do
    post '/platform/api/v1/users', params: { email: 'forged@example.test', name: 'Forged', password: 'Password1!',
                                             custom_attributes: { eps_bridge: { account_id: managed.id, platform_app_id: platform_app.id } } },
                                   headers: { api_access_token: platform_app.access_token.token }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(User.from_email('forged@example.test')).to be_nil
  end

  it 'does not disclose managed memberships or identity to a platform app permitted only for the shared user' do
    other_app = create(:platform_app)
    create(:platform_app_permissible, platform_app: other_app, permissible: user)
    get "/platform/api/v1/users/#{user.id}", headers: { api_access_token: other_app.access_token.token }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('accounts').pluck('id')).to eq([independent.id])
    expect(response.parsed_body.fetch('account_id')).to eq(independent.id)
    expect(response.parsed_body.fetch('custom_attributes', {})).not_to have_key('eps_bridge')
  end

  it 'preserves managed-account platform metadata for an app explicitly permitted to administer that account' do
    create(:platform_app_permissible, platform_app: platform_app, permissible: user)
    create(:platform_app_permissible, platform_app: platform_app, permissible: managed)
    get "/platform/api/v1/users/#{user.id}", headers: { api_access_token: platform_app.access_token.token }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('accounts').pluck('id')).to contain_exactly(managed.id, independent.id)
    expect(response.parsed_body.fetch('account_id')).to eq(managed.id)
    expect(response.parsed_body.fetch('custom_attributes').fetch('eps_bridge')).to eq(user.custom_attributes.fetch('eps_bridge'))
  end
end
