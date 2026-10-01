class Conversations::BulkEmailDeleteService
  class Error < StandardError; end

  pattr_initialize [:conversation!, :user!, :ip, :mode!]

  def perform
    channel = conversation.inbox.channel
    raise Error, 'This conversation is not an email conversation' unless channel.is_a?(Channel::Email)
    raise Error, 'This email inbox has no active IMAP connection' unless channel.imap_enabled? && !channel.reauthorization_required?

    messages = conversation.messages.incoming.select(:source_id, :content_attributes)
    source_ids = messages.map(&:source_id)
    raise Error, 'No received email messages with provider IDs were found' if source_ids.blank? || source_ids.any?(&:blank?)

    locations = messages.to_h { |message| [message.source_id, message.content_attributes['imap_location']] }
    Imap::DeleteMessagesService.new(channel: channel, source_ids: source_ids.uniq, locations: locations, mode: mode).perform
    Rails.logger.info(
      "[BulkEmailDelete] Provider #{mode} confirmed for conversation #{conversation.id}, " \
      "inbox #{conversation.inbox_id}, user #{user.id}"
    )
    Conversations::DeleteService.new(conversation: conversation, user: user, ip: ip).perform
  end
end
