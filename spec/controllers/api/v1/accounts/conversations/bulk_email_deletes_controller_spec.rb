require 'rails_helper'

RSpec.describe 'Bulk email deletion API', type: :request do
  let(:request_id) { SecureRandom.uuid }
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:path) { "/api/v1/accounts/#{account.id}/conversations/bulk_email_delete" }
  let(:deletion) { instance_double(Conversations::BulkEmailDeleteService, prepare: true, perform: { deleted: true }) }

  before do
    allow(Conversations::BulkEmailDeleteService).to receive(:new).and_return(deletion)
  end

  it 'requires administrator permission before provider deletion' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: channel.inbox, user: agent)
    expect(deletion).not_to receive(:perform)

    post path, headers: agent.create_new_auth_token, params: { request_id: request_id, ids: [conversation.display_id], mode: 'trash' }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects permanent purge even with a confirmation phrase' do
    admin = create(:user, account: account, role: :administrator)
    expect(deletion).not_to receive(:perform)

    post path, headers: admin.create_new_auth_token,
               params: { request_id: request_id, ids: [conversation.display_id], mode: 'permanent', confirmation: 'DELETE PERMANENTLY' }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'reports provider-confirmed deletion for an authorized request' do
    admin = create(:user, account: account, role: :administrator)
    expect(deletion).to receive(:perform)

    post path, headers: admin.create_new_auth_token, params: { request_id: request_id, ids: [conversation.display_id], mode: 'trash' }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['results']).to eq([{ 'id' => conversation.display_id, 'deleted' => true }])
  end

  it 'leaves a failed item visible to retry' do
    admin = create(:user, account: account, role: :administrator)
    allow(deletion).to receive(:perform).and_raise(Imap::DeleteMessagesService::Error, 'provider rejected move')

    post path, headers: admin.create_new_auth_token, params: { request_id: request_id, ids: [conversation.display_id], mode: 'trash' }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['results']).to eq([{ 'id' => conversation.display_id, 'error' => 'provider rejected move' }])
  end

  it 'returns a durable completed receipt after the local conversation has been removed' do
    admin = create(:user, account: account, role: :administrator)
    id = conversation.display_id
    EmailActionReceipt.create!(account: account, user: admin, request_id: request_id, mode: 'trash',
                               conversation_record_id: conversation.id, conversation_display_id: id, result: { deleted: true })
    conversation.destroy!
    expect(deletion).not_to receive(:perform)

    post path, headers: admin.create_new_auth_token, params: { request_id: request_id, ids: [id], mode: 'trash' }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['results']).to eq([{ 'id' => id, 'deleted' => true }])
  end

  it 'does not let a receipt be reused for a different action' do
    admin = create(:user, account: account, role: :administrator)
    EmailActionReceipt.create!(account: account, user: admin, request_id: request_id, mode: 'trash',
                               conversation_record_id: conversation.id, conversation_display_id: conversation.display_id, result: { deleted: true })
    expect(deletion).not_to receive(:perform)

    post path, headers: admin.create_new_auth_token, params: { request_id: request_id, ids: [conversation.display_id], mode: 'spam' }, as: :json

    expect(response.parsed_body['results'].first['error']).to include('different action')
  end

  it 'does not look up conversations or receipts outside the authorized account' do
    admin = create(:user, account: account, role: :administrator)
    other = create(:conversation, display_id: 99_001)
    expect(deletion).not_to receive(:perform)

    post path, headers: admin.create_new_auth_token, params: { request_id: request_id, ids: [other.display_id], mode: 'trash' }, as: :json

    expect(response.parsed_body['results']).to eq([{ 'id' => other.display_id, 'error' => 'Conversation not found' }])
  end

  [[], [1, 1], ['1'], [0], (1..26).to_a].each do |invalid_ids|
    it "rejects invalid selection #{invalid_ids.inspect} before provider work" do
      admin = create(:user, account: account, role: :administrator)
      expect(deletion).not_to receive(:perform)
      post path, headers: admin.create_new_auth_token, params: { request_id: request_id, ids: invalid_ids, mode: 'trash' }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
  it 'rejects legacy local-only deletion for email conversations' do
    admin = create(:user, account: account, role: :administrator)
    delete "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Conversation.exists?(conversation.id)).to be true
    expect(DeleteObjectJob).not_to have_been_enqueued
  end

  it 'persists the message selection before deferring a batch item for retry' do
    stub_const('Api::V1::Accounts::Conversations::BulkEmailDeletesController::BATCH_BUDGET_SECONDS', 0)
    allow(Conversations::BulkEmailDeleteService).to receive(:new).and_call_original
    admin = create(:user, account: account, role: :administrator)
    received = create(:message, account: account, conversation: conversation, inbox: channel.inbox, source_id: 'budget@example.test')
    expect(Imap::DeleteMessagesService).not_to receive(:new)

    post path, headers: admin.create_new_auth_token, params: { request_id: request_id, ids: [conversation.display_id], mode: 'trash' }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['results'].first['error']).to include('not started')
    expect(EmailActionReceipt.find_by!(request_id: request_id).message_ids).to include(received.id)
  end
end
