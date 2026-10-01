class EpsBridge::ProviderIsolation
  def self.tracked?(inbox)
    inbox&.api? && inbox.channel.additional_attributes['provider_delivery_tracking'] == true
  end

  def self.public_conversations(relation)
    relation.where.not(inbox_id: private_inbox_ids)
  end

  def self.public_contact_inboxes(relation)
    relation.where.not(inbox_id: private_inbox_ids)
  end

  def self.validate_message!(conversation, params, message_type, attributes)
    return unless tracked?(conversation.inbox)

    return if message_type == 'outgoing' && !owned_fields?(params, attributes || {})

    conversation.errors.add(:base, 'Provider-owned message fields require trusted proof')
    raise ActiveRecord::RecordInvalid, conversation
  end

  def self.owned_fields?(params, attributes)
    direct_fields = [:source_id, :sender_type, :sender_id].any? { |key| params[key].present? }
    owned_attributes = !attributes.respond_to?(:keys) || attributes.keys.map(&:to_s).intersect?(%w[external_echo external_error external_created_at])
    direct_fields || owned_attributes
  end
  private_class_method :owned_fields?

  def self.contact_tokens(contact_inbox)
    return [] if tracked?(contact_inbox.inbox)
    return [contact_inbox.pubsub_token] unless contact_inbox.hmac_verified?

    public_contact_inboxes(contact_inbox.contact.contact_inboxes.where(hmac_verified: true)).filter_map(&:pubsub_token)
  end

  def self.private_inbox_ids
    channels = Channel::Api.where('additional_attributes @> ?', { provider_delivery_tracking: true }.to_json)
    Inbox.where(channel_type: 'Channel::Api', channel_id: channels.select(:id)).select(:id)
  end
  private_class_method :private_inbox_ids
end
