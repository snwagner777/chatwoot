require 'rails_helper'

RSpec.describe EmailConversationLock do
  let(:channel) { create(:channel_email, :imap_email) }
  let(:conversation) { create(:conversation, account: channel.account, inbox: channel.inbox) }

  %w[incoming outgoing].each do |message_type|
    it "rejects a stale #{message_type} email append after its conversation was deleted" do
      message = build(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: message_type)
      Conversation.where(id: conversation.id).delete_all

      expect { message.save! }.to raise_error(ActiveRecord::RecordNotFound)
      expect(Message.where(conversation_id: conversation.id)).not_to exist
    end
  end
end
