require 'rails_helper'

RSpec.describe 'EPS managed Enterprise identity', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

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
