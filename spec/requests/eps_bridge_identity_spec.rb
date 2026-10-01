require 'rails_helper'

RSpec.describe 'EPS managed identity', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:platform_app) { create(:platform_app) }
  let(:headers) { { api_access_token: platform_app.access_token.token } }

  before do
    create(:platform_app_permissible, platform_app: platform_app, permissible: user)
    create(:platform_app_permissible, platform_app: platform_app, permissible: account)
  end

  it 'binds only an allowed account member and refuses rebinding to another EPS identity' do
    post "/platform/api/v1/users/#{user.id}/eps_identity", params: { core_user_id: 'eps-1', account_id: account.id }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(user.reload.custom_attributes['eps_bridge']).to include('core_user_id' => 'eps-1', 'platform_app_id' => platform_app.id)
    post "/platform/api/v1/users/#{user.id}/eps_identity", params: { core_user_id: 'other', account_id: account.id }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'does not issue unbound SSO links for managed staff' do
    post "/platform/api/v1/users/#{user.id}/eps_identity", params: { core_user_id: 'eps-1', account_id: account.id }, headers: headers, as: :json
    get "/platform/api/v1/users/#{user.id}/login", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    get "/platform/api/v1/users/#{user.id}/login", params: { eps_core_user_id: 'eps-1', eps_session_id: 'web-1', eps_account_id: account.id },
                                                   headers: headers
    expect(response).to have_http_status(:ok)
    token = Rack::Utils.parse_query(URI.parse(response.parsed_body['url']).query)['sso_auth_token']
    expect(user.eps_sso_session(token)).to include('web_session_id' => 'web-1', 'core_user_id' => 'eps-1', 'account_id' => account.id)
  end

  it 'rejects another account even when the user is permissible' do
    other = create(:account)
    post "/platform/api/v1/users/#{user.id}/eps_identity", params: { core_user_id: 'eps-1', account_id: other.id }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'keeps staff invitations in EPS Admin after an account is managed' do
    admin = create(:user, :administrator, account: account)
    account.update!(custom_attributes: { eps_managed: true })
    post "/api/v1/accounts/#{account.id}/agents", params: { email: 'new@example.test', name: 'New agent', role: 'agent' },
                                                  headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(User.from_email('new@example.test')).to be_nil
  end

  it 'rejects nested agent role changes outside EPS Admin' do
    admin = create(:user, :administrator, account: account)
    account.update!(custom_attributes: { eps_managed: true })
    patch "/api/v1/accounts/#{account.id}/agents/#{user.id}", params: { agent: { role: 'administrator' } },
                                                              headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(user.account_users.find_by!(account_id: account.id).role).to eq('agent')
  end

  it 'does not let the Enterprise update hook clear a managed custom role on a name update' do
    admin = create(:user, :administrator, account: account)
    custom_role = create(:custom_role, account: account)
    membership = user.account_users.find_by!(account_id: account.id)
    membership.update!(custom_role: custom_role)
    account.update!(custom_attributes: { eps_managed: true })
    patch "/api/v1/accounts/#{account.id}/agents/#{user.id}", params: { agent: { name: 'Different name' } },
                                                              headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(membership.reload.custom_role_id).to eq(custom_role.id)
  end
end
