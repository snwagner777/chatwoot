# Synthetic local QA only. Never load this file in a release image.
raise 'Synthetic QA only' unless ENV['INBOX2_SYNTHETIC_QA'] == '1' && ENV['POSTGRES_DATABASE'] == 'inbox2_synthetic_qa'

require 'rails'
class Inbox2SyntheticHarness < Rails::Railtie
  config.after_initialize do
    require 'webmock'
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
    WebMock.stub_request(:post, 'https://core.synthetic.test/api/v1/core/inbox2/session-status').to_return do |request|
      payload = request.headers['X-Eps-Bridge-Payload']
      supplied = request.headers['X-Eps-Bridge-Signature']
      claims = begin
        JSON.parse(Base64.urlsafe_decode64(payload.to_s))
      rescue StandardError
        {}
      end
      app = PlatformApp.find_by(name: 'Synthetic EPS Core')
      valid = app.present? && supplied == OpenSSL::HMAC.hexdigest('SHA256', app.access_token.token, payload.to_s)
      revoked = begin
        JSON.parse(File.read(File.join(ENV.fetch('INBOX2_QA_TMP_DIR'), 'revoked.json')))
      rescue StandardError
        []
      end
      active = valid && claims['purpose'] == 'session-status' && revoked.exclude?(claims['coreUserId'])
      { status: 200, body: { active: active }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
    Rails.application.config.active_job.queue_adapter = :test
    ActionMailer::Base.delivery_method = :test
  end
end
