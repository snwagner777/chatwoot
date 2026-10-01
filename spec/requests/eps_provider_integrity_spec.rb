require 'rails_helper'

RSpec.describe 'Provider-owned message fields', type: :request do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_api, account: account, additional_attributes: { provider_delivery_tracking: true }) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:path) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages" }

  it 'blocks browser source echoes and non-outgoing types while keeping normal replies and notes' do
    headers = user.create_new_auth_token
    base_params = { content: 'Untrusted provider state', message_type: 'outgoing' }
    [{ source_id: 'fake-provider-id' }, { message_type: 'incoming' }, { message_type: 'template' },
     { content_attributes: { external_echo: true } }].each do |extra|
      post path, params: base_params.merge(extra), headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end
    expect(conversation.messages.count).to eq(0)
    post path, params: { content: 'Normal reply', message_type: 'outgoing' }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(conversation.messages.last.status).to eq('pending')
    post path, params: { content: 'Private note', message_type: 'outgoing', private: true }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(conversation.messages.last).to be_private
  end

  it 'does not let an ordinary browser claim delivery' do
    message = create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing)
    patch "#{path}/#{message.id}", params: { status: 'delivered' }, headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(message.reload.status).to eq('pending')
  end

  it 'rejects provider fields in nested conversation creation and rolls back the conversation' do
    params = { inbox_id: channel.inbox.id, contact_id: conversation.contact.id, source_id: conversation.contact_inbox.source_id,
               message: { content: 'Forged history', message_type: 'incoming', source_id: 'fake-provider' } }
    count = account.conversations.count
    post "/api/v1/accounts/#{account.id}/conversations", params: params, headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(account.conversations.count).to eq(count)
  end

  it 'does not expose a public message-creation path for tracked provider inboxes' do
    base = "/public/api/v1/inboxes/#{channel.identifier}/contacts/#{conversation.contact_inbox.source_id}"
    target = "#{base}/conversations/#{conversation.display_id}/messages"
    post target, params: { content: 'Forged incoming message' }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(conversation.messages.count).to eq(0)
  end

  it 'excludes tracked conversations reachable through another verified public inbox on the same contact' do
    other_channel = create(:channel_api, account: account)
    public_binding = create(:contact_inbox, contact: conversation.contact, inbox: other_channel.inbox, hmac_verified: true)
    conversation.contact_inbox.update!(hmac_verified: true)
    base = "/public/api/v1/inboxes/#{other_channel.identifier}/contacts/#{public_binding.source_id}/conversations"
    get base
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq([])
    get "#{base}/#{conversation.display_id}"
    expect(response).to have_http_status(:forbidden)
    get "#{base}/#{conversation.display_id}/messages"
    expect(response).to have_http_status(:forbidden)
  end

  it 'accepts a one-use body-bound provider status proof but not its replay' do
    platform_app = create(:platform_app)
    user.update!(custom_attributes: { eps_bridge: { core_user_id: 'owner-1', platform_app_id: platform_app.id, account_id: account.id } })
    message = create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing)
    target = "#{path}/#{message.id}"
    body = { status: 'sent' }.to_json
    claims = { purpose: 'provider-operation', timestamp: Time.current.to_i, nonce: 'provider-test-1', coreUserId: 'owner-1',
               chatwootUserId: user.id, accountId: account.id, method: 'PATCH', path: target, bodyHash: Digest::SHA256.hexdigest(body) }
    payload = Base64.urlsafe_encode64(claims.to_json, padding: false)
    headers = { :api_access_token => user.access_token.token, 'Content-Type' => 'application/json',
                'x-eps-bridge-payload' => payload,
                'x-eps-bridge-signature' => OpenSSL::HMAC.hexdigest('SHA256', platform_app.access_token.token, payload) }
    patch target, params: body, headers: headers
    expect(response).to have_http_status(:ok)
    expect(message.reload.status).to eq('sent')
    patch target, params: body, headers: headers
    expect(response).to have_http_status(:unauthorized)
  end
end
