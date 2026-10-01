require 'rails_helper'

RSpec.describe 'EPS operator theme', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, :administrator, account: account) }

  it 'applies and clears the supported account theme' do
    patch "/api/v1/accounts/#{account.id}", params: { operator_theme: 'economyops' }, headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)
    expect(account.reload.custom_attributes['operator_theme']).to eq('economyops')
    patch "/api/v1/accounts/#{account.id}", params: { operator_theme: '' }, headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)
    expect(account.reload.custom_attributes).not_to have_key('operator_theme')
  end

  it 'rejects an unsupported theme before changing account fields' do
    original_name = account.name
    patch "/api/v1/accounts/#{account.id}", params: { operator_theme: 'external', name: 'Changed' },
                                            headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(account.reload.name).to eq(original_name)
  end
end
