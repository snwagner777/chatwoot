class Api::V1::Accounts::Conversations::BulkEmailDeletesController < Api::V1::Accounts::BaseController
  MAX_CONVERSATIONS = 25
  BATCH_BUDGET_SECONDS = 4
  REQUEST_ID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  def create
    ids = params[:ids]
    unless valid_request?(ids)
      return render json: { error: 'Select 1 to 25 conversations, a valid action and a unique request ID' }, status: :unprocessable_entity
    end

    # Check account-level administrator permission even for completed retries whose
    # conversation has already been removed. Receipts are always account scoped.
    authorize Conversation, :destroy?
    conversations = Current.account.conversations.where(display_id: ids).index_by(&:display_id)
    conversations.each_value { |conversation| authorize conversation, :destroy? }
    # Persist every selection before any provider mutation, including items that
    # must wait for a later retry when this request reaches its time budget.
    prepared = ids.index_with { |id| result_for(id, conversations[id], prepare: true) }
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    results = ids.map do |id|
      next prepared[id] if prepared[id]
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at >= BATCH_BUDGET_SECONDS
        next { id: id, error: 'This item was not started in this request. Retry the same selection to continue.' }
      end

      result_for(id, conversations[id])
    end
    render json: { results: results }
  end

  private

  def valid_request?(ids)
    return false unless %w[trash spam].include?(params[:mode])
    return false unless params[:request_id].is_a?(String) && params[:request_id].match?(REQUEST_ID_PATTERN)

    valid_ids?(ids)
  end

  def valid_ids?(ids)
    return false unless ids.is_a?(Array) && ids.any? && ids.size <= MAX_CONVERSATIONS

    ids.uniq.size == ids.size && ids.all? { |id| id.is_a?(Integer) && id.positive? }
  end

  def result_for(id, conversation, prepare: false)
    mode = params[:mode]
    receipt = EmailActionReceipt.find_by(account: Current.account, request_id: params[:request_id], conversation_display_id: id)
    if receipt
      return { id: id, error: 'This request was already used for a different action' } unless receipt.mode == mode
      return receipt.result.merge(id: id) if receipt.completed?
    end
    return { id: id, error: 'Conversation not found' } unless conversation

    service = Conversations::BulkEmailDeleteService.new(conversation: conversation, user: Current.user, ip: request.ip,
                                                        mode: mode, request_id: params[:request_id])
    if prepare
      service.prepare
      return
    end

    { id: id }.merge(service.perform)
  rescue Conversations::BulkEmailDeleteService::Error, Imap::DeleteMessagesService::Error => e
    { id: id, error: e.message }
  rescue StandardError => e
    Rails.logger.error("[BulkEmailDelete] Failed for conversation #{id}: #{e.class}")
    { id: id, error: 'The mail provider action was not confirmed. Retry this same action to reconcile it.' }
  end
end
