require 'rails_helper'

RSpec.describe 'Bulk email deletion API', type: :request do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:path) { "/api/v1/accounts/#{account.id}/conversations/bulk_email_delete" }
  let(:deletion) { instance_double(Conversations::BulkEmailDeleteService, perform: true) }

  before do
    allow(Conversations::BulkEmailDeleteService).to receive(:new).and_return(deletion)
  end

  it 'requires administrator permission before provider deletion' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: channel.inbox, user: agent)
    expect(deletion).not_to receive(:perform)

    post path, headers: agent.create_new_auth_token, params: { ids: [conversation.display_id], mode: 'trash' }, as: :json

    expect(response).to have_http_status(:forbidden)
  end

  it 'requires an action-time permanent deletion confirmation' do
    admin = create(:user, account: account, role: :administrator)
    expect(deletion).not_to receive(:perform)

    post path, headers: admin.create_new_auth_token, params: { ids: [conversation.display_id], mode: 'permanent' }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'reports provider-confirmed deletion for an authorized request' do
    admin = create(:user, account: account, role: :administrator)
    expect(deletion).to receive(:perform)

    post path, headers: admin.create_new_auth_token, params: { ids: [conversation.display_id], mode: 'trash' }, as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['results']).to eq([{ 'id' => conversation.display_id, 'deleted' => true }])
  end

  it 'leaves a failed item visible to retry' do
    admin = create(:user, account: account, role: :administrator)
    allow(deletion).to receive(:perform).and_raise(Imap::DeleteMessagesService::Error, 'provider rejected move')

    post path, headers: admin.create_new_auth_token, params: { ids: [conversation.display_id], mode: 'trash' }, as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['results']).to eq([{ 'id' => conversation.display_id, 'error' => 'provider rejected move' }])
  end
end
