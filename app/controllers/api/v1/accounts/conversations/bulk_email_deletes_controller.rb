class Api::V1::Accounts::Conversations::BulkEmailDeletesController < Api::V1::Accounts::BaseController
  MAX_CONVERSATIONS = 25

  def create
    ids = params[:ids]
    mode = params[:mode]
    valid_ids = ids.is_a?(Array) && ids.any? && ids.size <= MAX_CONVERSATIONS && ids.uniq.size == ids.size &&
                ids.all? { |id| id.is_a?(Integer) && id.positive? }
    unless valid_ids && %w[trash spam permanent].include?(mode)
      return render json: { error: 'Select 1 to 25 conversations and a valid deletion mode' }, status: :unprocessable_entity
    end
    if mode == 'permanent' && params[:confirmation] != 'DELETE PERMANENTLY'
      return render json: { error: 'Permanent deletion requires confirmation' }, status: :unprocessable_entity
    end

    conversations = Current.account.conversations.where(display_id: ids).index_by(&:display_id)
    conversations.each_value { |conversation| authorize conversation, :destroy? }
    results = ids.map do |id|
      conversation = conversations[id]
      next { id: id, error: 'Conversation not found' } unless conversation

      begin
        Conversations::BulkEmailDeleteService.new(conversation: conversation, user: Current.user, ip: request.ip, mode: mode).perform
        { id: id, deleted: true }
      rescue Conversations::BulkEmailDeleteService::Error, Imap::DeleteMessagesService::Error => e
        { id: id, error: e.message }
      rescue StandardError => e
        Rails.logger.error("[BulkEmailDelete] Failed for conversation #{conversation.id}: #{e.class}")
        { id: id, error: 'The mail provider did not confirm deletion. Retry this conversation.' }
      end
    end
    render json: { results: results }
  end
end
