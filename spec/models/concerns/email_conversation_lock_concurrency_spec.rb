require 'rails_helper'

RSpec.describe EmailConversationLock do
  self.use_transactional_tests = false

  let(:channel) { create(:channel_email, :imap_email) }
  let(:conversation) { create(:conversation, account: channel.account, inbox: channel.inbox).reload }

  after do
    connection = ActiveRecord::Base.connection
    tables = connection.tables - %w[schema_migrations ar_internal_metadata]
    connection.truncate_tables(*tables)
  end

  %w[incoming outgoing].each do |message_type|
    it "serializes a concurrent #{message_type} insert against deletion without silently discarding a saved reply" do
      message = build(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: message_type)
      started = Queue.new
      outcome = Queue.new
      writer = nil

      conversation.with_lock do
        writer = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            started << connection.select_value('SELECT pg_backend_pid()')
            begin
              message.save!
              outcome << :saved
            rescue ActiveRecord::RecordNotFound => e
              outcome << e
            end
          end
        end
        backend_pid = started.pop
        Timeout.timeout(5) do
          loop do
            waiting = ActiveRecord::Base.connection.select_value(
              "SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = #{Integer(backend_pid)}"
            )
            break if waiting
            raise 'Writer finished without acquiring the shared lock' unless outcome.empty?

            Thread.pass
          end
        end
        Conversation.where(id: conversation.id).delete_all
      end
      Timeout.timeout(5) { writer.join }

      expect(outcome.pop).to be_a(ActiveRecord::RecordNotFound)
      expect(Message.where(conversation_id: conversation.id)).not_to exist
    ensure
      writer&.kill if writer&.alive?
    end
  end
end
