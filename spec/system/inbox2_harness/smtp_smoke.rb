raise 'Synthetic QA only' unless ENV['INBOX2_SYNTHETIC_QA'] == '1' && ENV['POSTGRES_DATABASE'] == 'inbox2_synthetic_qa'

require 'factory_bot_rails'
require 'faker'
FactoryBot.find_definitions if FactoryBot.factories.count.zero?
account = Account.find_by!(name: 'EPS SYNTHETIC QA')
conversation = account.conversations.joins(:inbox).where(inboxes: { channel_type: 'Channel::Email' }).order(:id).first!
channel = conversation.inbox.channel
raise 'Local fixture only' unless channel.smtp_address == '127.0.0.1' && channel.smtp_port == 1025

message = FactoryBot.create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                                      sender: account.users.first, message_type: :outgoing, content: 'Synthetic SMTP transport reply')
SendReplyJob.perform_now(message.id)
raise 'Native SMTP did not assign a source ID' if message.reload.source_id.blank? || message.failed?

captured = JSON.parse(File.read(File.join(ENV.fetch('INBOX2_QA_TMP_DIR'), 'smtp-state.json')))
raise 'Wrong SMTP sender' unless captured.fetch('from').include?('inbox1@example.test')
raise 'Wrong SMTP recipient' unless captured.fetch('to').include?('customer-0-0@example.test')
raise 'Wrong SMTP body' unless captured.fetch('body').include?('Synthetic SMTP transport reply')

File.write(File.join(ENV.fetch('INBOX2_QA_TMP_DIR'), 'artifacts', 'smtp-result.json'),
           { synthetic: true, native_send_reply_job: 'passed', company_sender_routing: 'passed', local_smtp_capture: 'passed' }.to_json)
puts 'Native SMTP job and company sender routing passed against the loopback fixture'
