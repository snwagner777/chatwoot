require 'rails_helper'

RSpec.describe EpsBridge::SessionVerifier do
  let(:platform_app) { create(:platform_app) }
  let(:user) { create(:user, custom_attributes: { eps_bridge: { platform_app_id: platform_app.id, core_user_id: 'eps-1', account_id: 1 } }) }
  let(:binding) { { 'core_user_id' => 'eps-1', 'web_session_id' => 'web-1', 'account_id' => 1 } }
  let(:verifier) { described_class.new(user) }

  it 'exposes only a plain HTTPS application origin for navigation' do
    with_modified_env('EPS_CORE_ORIGIN' => 'https://ops.example.test') { expect(described_class.application_url).to eq('https://ops.example.test') }
    with_modified_env('EPS_CORE_ORIGIN' => 'javascript:alert(1)') { expect(described_class.application_url).to be_nil }
    with_modified_env('EPS_CORE_ORIGIN' => 'https://secret@ops.example.test') { expect(described_class.application_url).to be_nil }
  end

  it 'requires a matching EPS session and fails closed when Core revokes it' do
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      stub = stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status')
             .to_return(status: 200, body: '{"active":true}', headers: { 'Content-Type' => 'application/json' })
      expect(verifier.active?(binding)).to be true
      expect(stub).to have_been_requested.once
      expect(verifier.active?(binding.merge('core_user_id' => 'other'))).to be false
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 200, body: '{"active":false}')
      expect(verifier.active?(binding)).to be false
    end
  end

  it 'does not follow redirects or allow insecure callback origins' do
    with_modified_env 'EPS_CORE_ORIGIN' => 'https://core.example.test' do
      stub_request(:post, 'https://core.example.test/api/v1/core/inbox2/session-status').to_return(status: 302,
                                                                                                   headers: { 'Location' => 'https://other.test' })
      expect(verifier.active?(binding)).to be false
    end
    with_modified_env 'EPS_CORE_ORIGIN' => 'http://core.example.test' do
      expect(verifier.active?(binding)).to be false
    end
  end

  it 'requires body-bound one-use proof for direct managed-user API tokens' do
    payload = Base64.urlsafe_encode64({ purpose: 'native-proxy', timestamp: Time.current.to_i, nonce: 'nonce-1', coreUserId: 'eps-1',
                                        chatwootUserId: user.id, accountId: 1, method: 'POST', path: '/api/v1/accounts/1/conversations/2/messages',
                                        bodyHash: Digest::SHA256.hexdigest('{"content":"hello"}') }.to_json, padding: false)
    signature = OpenSSL::HMAC.hexdigest('SHA256', platform_app.access_token.token, payload)
    request = instance_double(ActionDispatch::Request, headers: { 'x-eps-bridge-payload' => payload, 'x-eps-bridge-signature' => signature },
                                                       request_method: 'POST', fullpath: '/api/v1/accounts/1/conversations/2/messages',
                                                       raw_post: '{"content":"hello"}')
    expect(verifier.valid_proxy?(request)).to be true
    expect(verifier.valid_proxy?(request)).to be false
  end
end
