require 'rails_helper'

RSpec.describe 'EPS browser session enforcement', type: :request do
  let(:account) { create(:account) }
  let(:platform_app) { create(:platform_app) }
  let(:user) do
    create(:user, account: account,
                  custom_attributes: { eps_bridge: { platform_app_id: platform_app.id, core_user_id: 'eps-1', account_id: account.id } })
  end

  it 'blocks unbound browser sessions and unsigned reusable API tokens for managed users' do
    get "/api/v1/accounts/#{account.id}", headers: user.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
    get "/api/v1/accounts/#{account.id}", headers: { api_access_token: user.access_token.token }
    expect(response).to have_http_status(:unauthorized)
  end

  it 'checks Core on each bound request so logout immediately blocks the next request' do
    headers = user.create_new_auth_token
    user.tokens[headers['client']]['eps_session'] = { 'core_user_id' => 'eps-1', 'web_session_id' => 'web-1', 'account_id' => account.id }
    user.save!
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":true}')
      get "/api/v1/accounts/#{account.id}", headers: headers
      expect(response).to have_http_status(:ok)
      get "/api/v1/accounts/#{account.id}", headers: headers
      expect(response).to have_http_status(:ok)
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":false}')
      get "/api/v1/accounts/#{account.id}", headers: headers
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'stores the EPS binding only during real EPS SSO' do
    binding = { 'core_user_id' => 'eps-1', 'web_session_id' => 'web-1', 'account_id' => account.id }
    token = user.generate_sso_auth_token(eps_session: binding)
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":true}')
      post '/auth/sign_in', params: { email: user.email, sso_auth_token: token }, as: :json
      expect(response).to have_http_status(:ok)
      expect(user.reload.tokens.dig(response.headers['client'], 'eps_session')).to eq(binding)
      post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'accounts')).to be_empty
      expect(user.reload.tokens.dig(response.headers['client'], 'eps_session')).to be_nil
    end
  end

  it 'normalizes native login whitespace and header email credentials without granting EPS access' do
    post '/auth/sign_in', params: { email: " #{user.email.upcase} ", password: 'Password1!' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'accounts')).to be_empty
    post '/auth/sign_in', headers: { email: " #{user.email} ", password: 'Password1!' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'accounts')).to be_empty
    expect(user.reload.tokens.values.pluck('eps_session')).to all(be_nil)
  end

  it 'uses an explicit empty plain-text callback for session verification' do
    binding = { 'core_user_id' => 'eps-1', 'web_session_id' => 'web-1', 'account_id' => account.id }
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      callback = stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status')
                 .with(headers: { 'Content-Type' => 'text/plain; charset=utf-8' }, body: '')
                 .to_return(status: 200, body: '{"active":true}')
      expect(EpsBridge::SessionVerifier.new(user).active?(binding)).to be(true)
      expect(callback).to have_been_requested.once
    end
  end
end
