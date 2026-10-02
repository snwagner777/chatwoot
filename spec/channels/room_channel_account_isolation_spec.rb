require 'rails_helper'

RSpec.describe RoomChannel, type: :channel do
  let(:managed) { create(:account, custom_attributes: { eps_managed: true }) }
  let(:independent) { create(:account) }
  let(:platform_app) { create(:platform_app) }
  let(:user) do
    create(:user, account: managed,
                  custom_attributes: { eps_bridge: { core_user_id: 'eps-1', account_id: managed.id, platform_app_id: platform_app.id } })
  end
  let(:auth) { user.create_new_auth_token }
  let(:eps_auth) do
    auth.tap do |headers|
      user.tokens[headers['client']]['eps_session'] = { 'core_user_id' => 'eps-1', 'web_session_id' => 'web-1', 'account_id' => managed.id }
      user.save!
    end
  end
  let(:native_params) { { user_id: user.id, pubsub_token: user.pubsub_token, account_id: independent.id } }
  let(:eps_params) { native_params.merge(account_id: managed.id, client_id: eps_auth['client'], access_token: eps_auth['access-token']) }
  let(:native_event) { { event: 'message.created', data: { account_id: independent.id, content: 'independent content' } } }
  let(:eps_event) { { event: 'message.created', data: { account_id: managed.id, content: 'managed content' } } }
  let(:callback_url) { 'https://core.example.test/api/v1/core/inbox2/session-status' }

  before do
    stub_connection
    create(:account_user, user: user, account: independent)
  end

  around do |example|
    with_modified_env('EPS_CORE_ORIGIN' => 'https://core.example.test') { example.run }
  end

  it 'keeps an independent subscription and presence alive during Core outages without calling Core' do
    callback = stub_request(:post, callback_url).to_timeout
    subscribe(native_params)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for("account_#{independent.id}")
    perform :update_presence
    subscription.send(:transmit_eps_event, native_event)
    expect(transmissions).to eq([native_event.deep_stringify_keys])
    expect(subscription).not_to be_rejected
    expect(callback).not_to have_been_requested
  end

  it 'keeps the independent stream alive after EPS revocation with an EPS client on the subscription' do
    callback = stub_request(:post, callback_url).to_return(status: 200, body: '{"active":false}')
    subscribe(eps_params.merge(account_id: independent.id))
    expect(subscription).to be_confirmed
    subscription.send(:transmit_eps_event, eps_event)
    subscription.send(:transmit_eps_event, native_event)
    perform :update_presence
    expect(transmissions).to eq([native_event.deep_stringify_keys])
    expect(subscription).not_to be_rejected
    expect(callback).to have_been_requested.once
  end

  it 'drops managed data on a shared native user stream without stopping independent events' do
    subscribe(native_params)
    subscription.send(:transmit_eps_event, eps_event.deep_stringify_keys)
    subscription.send(:transmit_eps_event, native_event.deep_stringify_keys)
    expect(transmissions).to eq([native_event.deep_stringify_keys])
    expect(subscription).not_to be_rejected
    expect(subscription).to have_stream_for(user.pubsub_token)
  end

  it 'denies an unbound member of a managed account even with a valid native access token' do
    native_user = create(:user, account: managed)
    native_auth = native_user.create_new_auth_token
    subscribe(user_id: native_user.id, pubsub_token: native_user.pubsub_token, account_id: managed.id,
              client_id: native_auth['client'], access_token: native_auth['access-token'])
    expect(subscription).to be_rejected
  end

  it 'rejects a managed subscription with a known EPS client but no access token' do
    stub_request(:post, callback_url).to_return(status: 200, body: '{"active":true}')
    subscribe(eps_params.except(:access_token))
    expect(subscription).to be_rejected
  end

  it 'rejects a managed subscription with a wrong access token' do
    stub_request(:post, callback_url).to_return(status: 200, body: '{"active":true}')
    subscribe(eps_params.merge(access_token: 'wrong-token'))
    expect(subscription).to be_rejected
  end

  it 'rejects an access token belonging to another valid client' do
    params = eps_params
    other_auth = user.create_new_auth_token
    stub_request(:post, callback_url).to_return(status: 200, body: '{"active":true}')
    subscribe(params.merge(access_token: other_auth['access-token']))
    expect(subscription).to be_rejected
  end

  it 'rejects an expired EPS-bound access token' do
    params = eps_params
    user.tokens[params[:client_id]]['expiry'] = 1.minute.ago.to_i
    user.save!
    subscribe(params)
    expect(subscription).to be_rejected
  end

  it 'allows a matching active EPS-bound token and rechecks Core before delivery' do
    callback = stub_request(:post, callback_url).to_return(status: 200, body: '{"active":true}')
    subscribe(eps_params)
    expect(subscription).to be_confirmed
    subscription.send(:transmit_eps_event, eps_event)
    expect(transmissions).to eq([eps_event.deep_stringify_keys])
    expect(callback).to have_been_requested.at_least_twice
  end

  it 'revokes a managed stream when its browser token is deleted while Core remains active' do
    stub_request(:post, callback_url).to_return(status: 200, body: '{"active":true}')
    subscribe(eps_params)
    user.update!(tokens: {})
    subscription.send(:transmit_eps_event, eps_event)
    expect(transmissions).to be_empty
    expect(subscription).to be_rejected
  end

  it 'rechecks managed account membership before delivery' do
    stub_request(:post, callback_url).to_return(status: 200, body: '{"active":true}')
    subscribe(eps_params)
    user.account_users.find_by!(account: managed).destroy!
    subscription.send(:transmit_eps_event, eps_event)
    expect(transmissions).to be_empty
    expect(subscription).to be_rejected
  end

  it 'rechecks independent account membership before presence updates' do
    user.update!(custom_attributes: {})
    subscribe(native_params)
    expect(subscription).to be_confirmed
    user.account_users.find_by!(account: independent).destroy!
    perform :update_presence
    expect(subscription).to be_rejected
    expect(subscription.streams).to be_empty
  end

  it 'rechecks managed status when an independent account becomes managed' do
    user.update!(custom_attributes: {})
    subscribe(native_params)
    expect(subscription).to be_confirmed
    independent.update!(custom_attributes: { eps_managed: true })
    subscription.send(:transmit_eps_event, native_event)
    expect(transmissions).to be_empty
    expect(subscription).to be_rejected
  end

  it 'drops managed-account events when that membership is removed without stopping the independent stream' do
    stub_request(:post, callback_url).to_return(status: 200, body: '{"active":true}')
    subscribe(eps_params.merge(account_id: independent.id))
    expect(subscription).to be_confirmed
    user.account_users.find_by!(account: managed).destroy!
    subscription.send(:transmit_eps_event, eps_event)
    subscription.send(:transmit_eps_event, native_event)
    expect(transmissions).to eq([native_event.deep_stringify_keys])
    expect(subscription).not_to be_rejected
  end

  it 'allows EPS events on the shared stream only with current matching EPS session proof' do
    callback = stub_request(:post, callback_url).to_return(status: 200, body: '{"active":true}')
    subscribe(eps_params.merge(account_id: independent.id))
    subscription.send(:transmit_eps_event, eps_event)
    expect(transmissions).to eq([eps_event.deep_stringify_keys])
    expect(callback).to have_been_requested.once
  end

  it 'preserves other native account events only while the user remains a member' do
    other = create(:account)
    membership = create(:account_user, user: user, account: other)
    event = { event: 'message.created', data: { account_id: other.id, content: 'other native content' } }
    subscribe(native_params)
    subscription.send(:transmit_eps_event, event)
    membership.destroy!
    subscription.send(:transmit_eps_event, event)
    expect(transmissions).to eq([event.deep_stringify_keys])
    expect(subscription).not_to be_rejected
  end

  it 'drops account-unscoped user events because their authorization cannot be established' do
    user.update!(custom_attributes: {})
    subscribe(native_params)
    subscription.send(:transmit_eps_event, { event: 'unknown.event', data: { content: 'unscoped content' } })
    expect(transmissions).to be_empty
    expect(subscription).not_to be_rejected
  end

  it 'preserves new native event types with a valid account and current membership' do
    user.update!(custom_attributes: {})
    subscribe(native_params)
    event = native_event.merge(event: 'future.native.event')
    subscription.send(:transmit_eps_event, event)
    expect(transmissions).to eq([event.deep_stringify_keys])
  end

  it 'drops malformed user event envelopes without stopping the native subscription' do
    subscribe(native_params)
    malformed = [nil, [], 'invalid', { event: 'unknown.event' }, { data: [] }, { data: 'invalid' }]
    aggregate_failures do
      malformed.each do |event|
        expect { subscription.send(:transmit_eps_event, event) }.not_to raise_error
      end
      expect(transmissions).to be_empty
      expect(subscription).not_to be_rejected
    end
  end

  it 'drops noncanonical account identifiers instead of letting Active Record coerce them' do
    subscribe(native_params)
    invalid_ids = [[independent.id], { id: independent.id }, independent.id.to_f, "#{independent.id}junk", "0#{independent.id}", 0, -1]
    aggregate_failures do
      invalid_ids.each do |id|
        event = { event: 'message.created', data: { account_id: id, content: 'ambiguous account content' } }
        expect { subscription.send(:transmit_eps_event, event) }.not_to raise_error
      end
      expect(transmissions).to be_empty
      expect(subscription).not_to be_rejected
    end
  end

  it 'preserves canonical string account identifiers emitted in JSON' do
    subscribe(native_params)
    event = { event: 'message.created', data: { account_id: independent.id.to_s, content: 'independent content' } }
    subscription.send(:transmit_eps_event, event)
    expect(transmissions).to eq([event.deep_stringify_keys])
  end

  it 'installs event authorization on both native user and account streams' do
    user.update!(custom_attributes: {})
    subscribe(native_params)
    handlers = {}
    allow(subscription).to receive(:stream_from) { |name, coder: nil, &handler| handlers[name] = [coder, handler] }
    subscription.send(:ensure_stream)
    expect(handlers.keys).to contain_exactly(user.pubsub_token, "account_#{independent.id}")
    handlers.each_value do |coder, handler|
      expect(coder).to eq(ActiveSupport::JSON)
      expect(handler).to be_a(Proc)
      handler.call(eps_event.deep_stringify_keys)
    end
    expect(transmissions).to be_empty
  end
end
