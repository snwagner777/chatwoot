class Messages::StatusUpdateService
  attr_reader :message, :status, :external_error

  def initialize(message, status, external_error = nil)
    @message = message
    @status = status.to_s
    @external_error = external_error
  end

  def perform
    # Lock the row and re-check the transition inside the lock so concurrent
    # webhook workers can't race past the forward-only guard.
    message.with_lock do
      next false unless valid_status_transition?

      update_message_status
    end
  end

  private

  def update_message_status
    message.update!(
      status: status,
      external_error: resolved_external_error
    )
  end

  def resolved_external_error
    return nil unless status == 'failed'

    # Preserve existing error if no new error provided
    external_error || message.external_error
  end

  def valid_status_transition?
    return false unless Message.statuses.key?(status)
    return valid_provider_transition? if message.provider_delivery_tracking?
    return false if %w[pending delivery_unknown].include?(status)

    current_status = message.status
    new_priority = Message.statuses[status]
    current_priority = Message.statuses[current_status] || -1

    # Allow: forward transitions, any transition to/from failed, or from nil
    status == 'failed' || current_status == 'failed' || new_priority >= current_priority
  end

  def valid_provider_transition?
    transitions = {
      'pending' => %w[pending delivery_unknown sent delivered read failed],
      'delivery_unknown' => %w[delivery_unknown sent delivered read failed],
      'sent' => %w[sent delivered read failed],
      'delivered' => %w[delivered read],
      'read' => %w[read],
      'failed' => %w[failed]
    }
    transitions.fetch(message.status, []).include?(status)
  end
end
