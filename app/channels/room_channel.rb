class RoomChannel < ApplicationCable::Channel
  def subscribed
    # TODO: should we only do ensure stream  if current account is present?
    # for now going ahead with guard clauses in update_subscription and broadcast_presence
    current_user
    current_account
    return unless verify_eps_stream

    ensure_stream
    update_subscription
    broadcast_presence
  end

  def update_presence
    return unless verify_eps_stream

    update_subscription
    broadcast_presence
  end

  private

  def broadcast_presence
    return if @current_account.blank?

    data = { account_id: @current_account.id, users: ::OnlineStatusTracker.get_available_users(@current_account.id) }
    data[:contacts] = ::OnlineStatusTracker.get_available_contacts(@current_account.id) if @current_user.is_a? User
    ActionCable.server.broadcast(pubsub_token, { event: 'presence.update', data: data })
  end

  def ensure_stream
    stream_from(pubsub_token, coder: ActiveSupport::JSON) { |data| transmit_eps_event(data) }
    return unless @current_account.present? && @current_user.is_a?(User)

    stream_from("account_#{@current_account.id}", coder: ActiveSupport::JSON) { |data| transmit_eps_event(data) }
  end

  def transmit_eps_event(data)
    return unless verify_eps_stream
    return if @current_user.is_a?(User) && !authorized_user_event?(data)

    transmit(data)
  end

  # User pubsub tokens span accounts, so each event needs its own account authorization.
  def authorized_user_event?(data)
    return false unless data.is_a?(Hash)

    payload = data.with_indifferent_access[:data]
    return false unless payload.is_a?(Hash)

    account_id = payload[:account_id]
    return false unless (account_id.is_a?(Integer) || account_id.is_a?(String)) && account_id.to_s.match?(/\A[1-9]\d*\z/)
    return true if account_id.to_s == @current_account.id.to_s

    authorized_user_account?(account_id)
  end

  def verify_eps_stream
    return verify_provider_contact_stream if @current_user.is_a?(Contact)
    return true unless @current_user.is_a?(User)

    @current_user.reload
    return true if authorized_user_account?(@current_account&.id)

    stop_all_streams
    reject
    false
  end

  def authorized_user_account?(account_id)
    account = @current_user.accounts.find_by(id: account_id)
    return false if account.blank?

    verifier = EpsBridge::SessionVerifier.new(@current_user)
    return true unless verifier.managed_account?(account)

    @current_user.valid_token?(params[:access_token], params[:client_id]) && verifier.active_client?(params[:client_id], account.id)
  end

  def verify_provider_contact_stream
    return true unless EpsBridge::ProviderIsolation.tracked?(@current_contact_inbox.reload.inbox)

    stop_all_streams
    reject
    false
  rescue ActiveRecord::RecordNotFound
    stop_all_streams
    reject
    false
  end

  def update_subscription
    return if @current_account.blank?

    ::OnlineStatusTracker.update_presence(@current_account.id, @current_user.class.name, @current_user.id)
  end

  def pubsub_token
    @pubsub_token ||= params[:pubsub_token]
  end

  def current_user
    @current_user ||= if params[:user_id].blank?
                        @current_contact_inbox = ContactInbox.find_by!(pubsub_token: pubsub_token)
                        @current_contact_inbox.contact
                      else
                        User.find_by!(pubsub_token: pubsub_token, id: params[:user_id])
                      end
  end

  def current_account
    return if current_user.blank?

    @current_account ||= if @current_user.is_a? Contact
                           @current_user.account
                         else
                           @current_user.accounts.find(params[:account_id])
                         end
  end
end
