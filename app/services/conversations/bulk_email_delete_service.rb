class Conversations::BulkEmailDeleteService
  class Error < StandardError; end

  pattr_initialize [:conversation!, :user!, :ip, :mode!, :request_id!]

  def prepare
    raise Error, 'Unsupported email action' unless %w[trash spam].include?(mode)

    eligible_channel!
    find_or_create_receipt
  end

  def perform
    raise Error, 'Unsupported email action' unless %w[trash spam].include?(mode)

    channel = eligible_channel!

    receipt = find_or_create_receipt
    raise Error, 'This request was already used for a different action' unless receipt.mode == mode
    return receipt.result.symbolize_keys if receipt.completed?

    failure = nil
    # Ordinary email inserts and data imports acquire this same row lock. Never
    # hand whole-conversation cleanup to an asynchronous job after releasing it.
    conversation.with_lock('FOR UPDATE NOWAIT') do
      receipt.lock!
      return receipt.result.symbolize_keys if receipt.completed?

      begin
        perform_provider_action(channel, receipt)
        finish_local_action(receipt)
      rescue StandardError => e
        # Commit partial receipts before raising outside this transaction. A retry
        # reconciles the original snapshot against the provider destination.
        failure = e
      end
    end
    raise failure if failure

    receipt.result.symbolize_keys
  end

  private

  def eligible_channel!
    channel = conversation.inbox.channel
    raise Error, 'This conversation is not an email conversation' unless channel.is_a?(Channel::Email)
    raise Error, 'This email inbox has no active IMAP connection' unless channel.imap_enabled? && !channel.reauthorization_required?

    channel
  end

  def perform_provider_action(channel, receipt)
    ensure_snapshot_unchanged!(receipt)
    pending_source_ids = receipt.source_ids - receipt.confirmed_source_ids
    return if pending_source_ids.empty?

    Imap::DeleteMessagesService.new(channel: channel, source_ids: pending_source_ids,
                                    locations: receipt.locations, mode: mode).perform do |source_id|
      receipt.update!(confirmed_source_ids: receipt.confirmed_source_ids | [source_id])
    end
    ensure_snapshot_unchanged!(receipt)
    raise Error, 'The mail provider did not confirm every selected message' unless (receipt.source_ids - receipt.confirmed_source_ids).empty?
  end

  def find_or_create_receipt
    conversation.with_lock('FOR UPDATE NOWAIT') do
      EmailActionReceipt.create_or_find_by!(account: conversation.account, request_id: request_id,
                                            conversation_display_id: conversation.display_id) do |receipt|
        receipt.assign_attributes(snapshot_attributes.merge(user: user, conversation_record_id: conversation.id, mode: mode))
      end
    end
  end

  def snapshot_attributes
    messages = conversation.messages.incoming.to_a
    source_ids = messages.map(&:source_id)
    raise Error, 'No received email messages with provider IDs were found' if source_ids.blank? || source_ids.any?(&:blank?)

    { message_ids: conversation.messages.reorder(:id).pluck(:id), source_ids: source_ids.uniq,
      locations: messages.to_h { |message| [message.source_id, message.content_attributes['imap_location']] } }
  end

  def ensure_snapshot_unchanged!(receipt)
    return if receipt.message_ids == conversation.messages.reorder(:id).pluck(:id)

    raise Error, 'New activity arrived. This conversation was retained. Close this dialog, review the conversation and start a new action.'
  end

  def finish_local_action(receipt)
    if mode == 'spam'
      conversation.update!(label_list: conversation.label_list | ['spam'], status: :resolved)
      receipt.update!(result: { spam: true })
    else
      Imap::DeletedMessageTracker.new(inbox: conversation.inbox).record(receipt.source_ids)
      DeleteObjectJob.perform_now(conversation, user, ip)
      receipt.update!(result: { deleted: true })
    end
    Rails.logger.info("[BulkEmailDelete] Provider #{mode} confirmed for conversation #{receipt.conversation_record_id}, user #{user.id}")
  end
end
