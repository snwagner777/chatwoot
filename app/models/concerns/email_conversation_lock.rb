# Deletion and email inserts must synchronize explicitly: messages has no database
# foreign key to conversations. The lock stays held for the insert transaction.
module EmailConversationLock
  extend ActiveSupport::Concern

  included do
    before_create :lock_existing_email_conversation
  end

  private

  def lock_existing_email_conversation
    Conversation.lock.find(conversation_id) if inbox.email?
  end
end
