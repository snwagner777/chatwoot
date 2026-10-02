require 'rails_helper'

RSpec.describe 'EPS Enterprise account isolation', type: :request do
  let(:managed) { create(:account, custom_attributes: { eps_managed: true }) }
  let(:independent) { create(:account) }
  let(:platform_app) { create(:platform_app) }
  let(:user) do
    create(:user, account: managed, role: :administrator,
                  custom_attributes: { eps_bridge: { account_id: managed.id, platform_app_id: platform_app.id, core_user_id: 'eps-1' } })
  end
  let(:headers) { user.create_new_auth_token }

  before do
    create(:account_user, user: user, account: independent, role: :administrator)
    allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
  end

  it 'protects the actual managed account id from native sessions and unsigned API tokens' do
    get "/enterprise/api/v1/accounts/#{managed.id}/limits?account_id=#{independent.id}", headers: headers
    expect(response).to have_http_status(:unauthorized)
    get "/enterprise/api/v1/accounts/#{managed.id}/limits", headers: { api_access_token: user.access_token.token }
    expect(response).to have_http_status(:unauthorized)
    expect do
      post "/enterprise/api/v1/accounts/#{managed.id}/subscription", headers: headers
    end.not_to have_enqueued_job(Enterprise::CreateStripeCustomerJob)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'keeps independent Enterprise access available during an EPS outage' do
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      callback = stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_timeout
      get "/enterprise/api/v1/accounts/#{independent.id}/limits", headers: headers
      expect(response).to have_http_status(:ok)
      get "/enterprise/api/v1/accounts/#{independent.id}/limits", headers: { api_access_token: user.access_token.token }
      expect(response).to have_http_status(:ok)
      expect(callback).not_to have_been_requested
    end
  end

  it 'requires a current EPS session only for the managed Enterprise account' do
    headers
    user.tokens[headers['client']]['eps_session'] = { 'account_id' => managed.id, 'core_user_id' => 'eps-1', 'web_session_id' => 'web-1' }
    user.save!
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":true}')
      get "/enterprise/api/v1/accounts/#{managed.id}/limits", headers: headers
      expect(response).to have_http_status(:ok)
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":false}')
      get "/enterprise/api/v1/accounts/#{managed.id}/limits", headers: headers
      expect(response).to have_http_status(:unauthorized)
      get "/enterprise/api/v1/accounts/#{independent.id}/limits", headers: headers
      expect(response).to have_http_status(:ok)
    end
  end
end
