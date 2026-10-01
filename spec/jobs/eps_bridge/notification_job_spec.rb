require 'rails_helper'

RSpec.describe EpsBridge::NotificationJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account, custom_attributes: { eps_managed: true }) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:platform) { create(:platform_app) }
  let(:conversation) { create(:conversation, account: account) }
  let(:endpoint) { 'https://core.example.test/api/v1/core/inbox2/notifications' }
  let(:notification) { create(:notification, account: account, user: user, primary_actor: conversation) }

  around do |example|
    with_modified_env(EPS_CORE_ORIGIN: 'https://core.example.test', EPS_NATIVE_NOTIFICATIONS_ENABLED: 'true') { example.run }
  end

  before do
    user.update!(custom_attributes: { eps_bridge: { platform_app_id: platform.id, core_user_id: 'synthetic-user', account_id: account.id } })
    create(:platform_app_permissible, platform_app: platform, permissible: account)
    create(:platform_app_permissible, platform_app: platform, permissible: user)
    user.notification_settings.find_by!(account_id: account.id).update!(push_conversation_assignment: true)
    clear_enqueued_jobs
  end

  it 'queues a content-free delivery by persisted notification ID after create' do
    created = notification
    jobs = enqueued_jobs.select { |job| job[:job].name == 'EpsBridge::NotificationJob' }
    expect(jobs.map { |job| job[:args] }).to eq([[created.id]])
  end

  it 'signs only strict routing claims and posts an empty body to Core' do
    expected = { 'purpose' => 'notification', 'timestamp' => Time.current.to_i, 'accountId' => account.id,
                 'chatwootUserId' => user.id, 'conversationId' => conversation.display_id, 'notificationId' => notification.id }
    request = stub_request(:post, endpoint).with do |sent|
      payload = sent.headers['X-Eps-Bridge-Payload']
      claims = JSON.parse(Base64.urlsafe_decode64(payload))
      expected['timestamp'] = claims['timestamp']
      claims == expected && (Time.current.to_i - claims['timestamp']).abs < 5 && sent.body.to_s.empty? &&
        sent.headers['X-Eps-Bridge-Signature'] == OpenSSL::HMAC.hexdigest('SHA256', platform.access_token.token, payload)
    end.to_return(status: 202)
    described_class.perform_now(notification.id)
    expect(request).to have_been_requested.once
  end

  it 'does not queue when the rollout flag is off' do
    with_modified_env(EPS_NATIVE_NOTIFICATIONS_ENABLED: 'false') { notification }
    expect(enqueued_jobs.none? { |job| job[:job].name == 'EpsBridge::NotificationJob' }).to be true
  end

  it 'uses an empty plain-text body that the Core parser accepts' do
    stub_request(:post, endpoint).to_return(status: 202)
    described_class.perform_now(notification.id)
    expect(a_request(:post, endpoint).with(headers: { 'Content-Type' => 'text/plain; charset=utf-8' }, body: '')).to have_been_made.once
  end

  it 'skips a read notification on retry' do
    notification.update!(read_at: Time.current)
    described_class.perform_now(notification.id)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it 'rechecks the rollout flag on queued delivery' do
    id = notification.id
    with_modified_env(EPS_NATIVE_NOTIFICATIONS_ENABLED: 'false') { described_class.perform_now(id) }
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it 'skips snoozed notifications' do
    notification.update!(snoozed_until: 1.hour.from_now)
    described_class.perform_now(notification.id)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it 'rechecks the agent conversation permission on delivery' do
    notification
    user.account_users.find_by!(account_id: account.id).update!(role: :agent)
    described_class.perform_now(notification.id)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it 'skips a mismatched conversation account' do
    notification.update!(primary_actor: create(:conversation))
    described_class.perform_now(notification.id)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it 'rechecks platform account access on delivery' do
    notification
    platform.platform_app_permissibles.find_by!(permissible: account).destroy!
    described_class.perform_now(notification.id)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it 'skips a deleted notification on retry' do
    id = notification.id
    notification.destroy!
    described_class.perform_now(id)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it 'rechecks native notification preferences before delivery' do
    notification
    user.notification_settings.find_by!(account_id: account.id).update!(push_conversation_assignment: false)
    described_class.perform_now(notification.id)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it 'rechecks account membership before delivery' do
    notification
    user.account_users.find_by!(account_id: account.id).destroy!
    described_class.perform_now(notification.id)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it 'rejects a mismatched identity account without sending' do
    notification
    user.update!(custom_attributes: { eps_bridge: { platform_app_id: platform.id, core_user_id: 'synthetic-user', account_id: account.id + 1 } })
    described_class.perform_now(notification.id)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it 'does not follow a redirect from Core' do
    request = stub_request(:post, endpoint).to_return(status: 302, headers: { Location: 'https://outside.example.test' })
    described_class.perform_now(notification.id)
    expect(request).to have_been_requested.once
    expect(a_request(:any, 'https://outside.example.test')).not_to have_been_made
  end

  it 'retries an unavailable Core with only the notification ID' do
    stub_request(:post, endpoint).to_return(status: 503)
    id = notification.id
    clear_enqueued_jobs
    described_class.perform_now(id)
    expect(enqueued_jobs.select { |job| job[:job].name == 'EpsBridge::NotificationJob' }.map { |job| job[:args] }).to eq([[id]])
  end

  it 'does not retry a terminal Core permission rejection' do
    stub_request(:post, endpoint).to_return(status: 403)
    id = notification.id
    clear_enqueued_jobs
    described_class.perform_now(id)
    expect(enqueued_jobs.none? { |job| job[:job].name == 'EpsBridge::NotificationJob' }).to be true
  end

  it 'bounds the discarded Core response' do
    stub_request(:post, endpoint).to_return(status: 202, body: 'x' * 4097)
    id = notification.id
    clear_enqueued_jobs
    described_class.perform_now(id)
    expect(enqueued_jobs.select { |job| job[:job].name == 'EpsBridge::NotificationJob' }.map { |job| job[:args] }).to eq([[id]])
  end

  it 'retries a network timeout with only the notification ID' do
    stub_request(:post, endpoint).to_timeout
    id = notification.id
    clear_enqueued_jobs
    described_class.perform_now(id)
    expect(enqueued_jobs.select { |job| job[:job].name == 'EpsBridge::NotificationJob' }.map { |job| job[:args] }).to eq([[id]])
  end

  it 'does not escape to the Sidekiq retry layer after the fifth failed attempt' do
    stub_request(:post, endpoint).to_return(status: 503)
    job = described_class.new(notification.id)
    job.exception_executions = { [EpsBridge::NotificationDelivery::Unavailable].to_s => 4 }
    clear_enqueued_jobs
    expect { job.perform_now }.not_to raise_error
    expect(enqueued_jobs.none? { |entry| entry[:job].name == 'EpsBridge::NotificationJob' }).to be true
  end
end
