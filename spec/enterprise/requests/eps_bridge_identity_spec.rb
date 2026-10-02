require 'rails_helper'

RSpec.describe 'EPS managed Enterprise identity', type: :request do
  let(:account) { create(:account) }
  let(:platform_app) { create(:platform_app) }
  let(:user) { create(:user, account: account) }

  around { |example| with_modified_env('EPS_CORE_ORIGIN' => 'https://core.example.test', &example) }

  it 'does not let the Enterprise update hook clear a managed custom role on a name update' do
    admin = create(:user, :administrator, account: account)
    custom_role = create(:custom_role, account: account)
    membership = user.account_users.find_by!(account_id: account.id)
    membership.update!(custom_role: custom_role)
    EpsBridge::IdentityBinding.new(platform_app, admin).tap do |identity|
      unless platform_app.platform_app_permissibles.exists?(permissible: account)
        create(:platform_app_permissible, platform_app: platform_app,
                                          permissible: account)
      end
      identity.link!('eps-admin', account.id)
    end
    admin_headers = admin.create_new_auth_token
    admin.tokens[admin_headers['client']]['eps_session'] = { 'core_user_id' => 'eps-admin', 'web_session_id' => 'web-1', 'account_id' => account.id }
    admin.save!
    stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":true}')
    patch "/api/v1/accounts/#{account.id}/agents/#{user.id}", params: { agent: { name: 'Different name' } },
                                                              headers: admin_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(membership.reload.custom_role_id).to eq(custom_role.id)
  end
end
