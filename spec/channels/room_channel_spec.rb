require 'rails_helper'

RSpec.describe RoomChannel do
  let!(:contact_inbox) { create(:contact_inbox) }
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }

  before do
    stub_connection
  end

  it 'subscribes to a stream when pubsub_token is provided' do
    subscribe(pubsub_token: contact_inbox.pubsub_token)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(contact_inbox.pubsub_token)
  end

  it 'subscribes to a stream when pubsub_token is provided for user' do
    subscribe(user_id: user.id, pubsub_token: user.pubsub_token, account_id: account.id)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(user.pubsub_token)
    expect(subscription).to have_stream_for("account_#{account.id}")
  end

  it 'rejects a managed user without an EPS-bound browser client' do
    user.update!(custom_attributes: { eps_bridge: { core_user_id: 'eps-1', account_id: account.id } })
    subscribe(user_id: user.id, pubsub_token: user.pubsub_token, account_id: account.id)
    expect(subscription).to be_rejected
  end

  it 'revokes a retained contact stream when its inbox becomes provider-tracked' do
    channel = create(:channel_api, account: account)
    binding = create(:contact_inbox, inbox: channel.inbox)
    subscribe(pubsub_token: binding.pubsub_token)
    expect(subscription).to be_confirmed
    channel.update!(additional_attributes: { provider_delivery_tracking: true })
    subscription.send(:transmit_eps_event, { event: 'message.created', data: { content: 'private provider content' } })
    expect(transmissions).to be_empty
    expect(subscription).to be_rejected
  end

  it 'stops an existing managed stream after EPS logout before transmitting another event' do
    platform_app = create(:platform_app)
    user.update!(custom_attributes: { eps_bridge: { core_user_id: 'eps-1', account_id: account.id, platform_app_id: platform_app.id } })
    auth = user.create_new_auth_token
    user.tokens[auth['client']]['eps_session'] = { 'core_user_id' => 'eps-1', 'web_session_id' => 'web-1', 'account_id' => account.id }
    user.save!
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":true}')
      subscribe(user_id: user.id, pubsub_token: user.pubsub_token, account_id: account.id,
                client_id: auth['client'], access_token: auth['access-token'])
      expect(subscription).to be_confirmed
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":false}')
      subscription.send(:transmit_eps_event, { event: 'message.created', data: { account_id: account.id, content: 'not delivered after logout' } })
      expect(transmissions).to be_empty
      expect(subscription).to be_rejected
    end
  end
end
