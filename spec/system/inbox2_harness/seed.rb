require 'factory_bot_rails'
require 'faker'
FactoryBot.find_definitions if FactoryBot.factories.count.zero?
ActiveJob::Base.queue_adapter = :test
raise 'Synthetic database required' unless ActiveRecord::Base.connection_db_config.database == 'inbox2_synthetic_qa'

ConfigLoader.new.process
platform = PlatformApp.create!(name: 'Synthetic EPS Core')
accounts = %w[EPS Partner].map do |name|
  FactoryBot.create(:account, name: "#{name} SYNTHETIC QA", support_email: "support@#{name.downcase}.example.test",
                              custom_attributes: { operator_theme: name == 'EPS' ? 'economyops' : 'neutral', eps_managed: true })
end
users = []
roles = %w[administrator agent]
topics = ['Leaking kitchen tap', 'Water heater appointment', 'Test promotion for Junk']
accounts.each_with_index do |account, index|
  roles.each do |role|
    user = FactoryBot.create(:user, account: account, role: role, name: "Synthetic #{role.capitalize} #{index + 1}",
                                    display_name: "QA #{role}", email: "#{role}#{index + 1}@example.test")
    identity = { platform_app_id: platform.id, core_user_id: "qa-#{index + 1}-#{role}", account_id: account.id }
    user.update!(custom_attributes: { eps_bridge: identity })
    PlatformAppPermissible.create!(platform_app: platform, permissible: user)
    binding = { 'core_user_id' => identity[:core_user_id], 'web_session_id' => "qa-session-#{user.id}", 'account_id' => account.id }
    token = user.generate_sso_auth_token(eps_session: binding)
    users << { id: user.id, name: user.name, email: user.email, role: role, account_id: account.id,
               core_user_id: identity[:core_user_id], url: "http://127.0.0.1:4310/app/login?email=#{CGI.escape(user.email)}&sso_auth_token=#{token}" }
  end
  PlatformAppPermissible.create!(platform_app: platform, permissible: account)
  email = Channel::Email.create!(account: account, email: "inbox#{index + 1}@example.test", imap_enabled: true,
                                 imap_address: '127.0.0.1', imap_port: 1143, imap_enable_ssl: false, imap_authentication: 'login',
                                 imap_login: 'synthetic', imap_password: 'synthetic-only', smtp_enabled: true,
                                 smtp_address: '127.0.0.1', smtp_port: 1025, smtp_enable_starttls_auto: false,
                                 smtp_login: 'synthetic', smtp_password: 'synthetic-only')
  email_inbox = FactoryBot.create(:inbox, account: account, channel: email, name: 'Email · synthetic test server')
  api_channel = Channel::Api.create!(account: account, additional_attributes: { provider_delivery_tracking: true })
  api_inbox = FactoryBot.create(:inbox, account: account, channel: api_channel, name: 'SMS · synthetic provider')
  account.users.each { |user| [email_inbox, api_inbox].each { |inbox| InboxMember.create!(user: user, inbox: inbox) } }
  topics.each_with_index do |topic, i|
    contact = FactoryBot.create(:contact, account: account, name: "Synthetic Customer #{index + 1}-#{i + 1}",
                                          email: "customer-#{index}-#{i}@example.test")
    conversation = FactoryBot.create(:conversation, account: account, inbox: email_inbox, contact: contact,
                                                    assignee: account.users.first, additional_attributes: { mail_subject: "[SYNTHETIC] #{topic}" })
    FactoryBot.create(:message, account: account, inbox: email_inbox, conversation: conversation, sender: contact,
                                source_id: "synthetic-#{index}-#{i}@example.test",
                                content: "Synthetic QA only: #{topic}. No real customer or provider data.")
  end
  contact = FactoryBot.create(:contact, account: account, name: "Synthetic SMS Customer #{index + 1}", phone_number: "+1202555010#{index}")
  conversation = FactoryBot.create(:conversation, account: account, inbox: api_inbox, contact: contact, assignee: account.users.first)
  FactoryBot.create(:message, account: account, inbox: api_inbox, conversation: conversation, sender: contact,
                              content: 'Synthetic appointment confirmation request')
  FactoryBot.create(:message, account: account, inbox: api_inbox, conversation: conversation, sender: account.users.first,
                              message_type: :outgoing, content: 'Synthetic reply awaiting provider confirmation')
end
account_data = accounts.map do |account|
  email_ids = account.conversations.joins(:inbox).where(inboxes: { channel_type: 'Channel::Email' }).order(:id).pluck(:display_id)
  sms_id = account.conversations.joins(:inbox).where(inboxes: { channel_type: 'Channel::Api' }).pick(:display_id)
  { id: account.id, name: account.name, email_ids: email_ids, sms_id: sms_id }
end
File.write(File.join(ENV.fetch('INBOX2_QA_TMP_DIR'), 'fixtures.json'), { synthetic: true, accounts: account_data, users: users }.to_json)
puts "Seeded #{accounts.length} synthetic accounts and #{users.length} EPS-bound users"
