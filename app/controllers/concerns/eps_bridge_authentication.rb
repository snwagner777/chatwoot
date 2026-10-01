module EpsBridgeAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :verify_eps_bridge_session
  end

  private

  def create_eps_initial_message(conversation)
    Messages::MessageBuilder.new(Current.user, conversation, params[:message], provider_verified: trusted_provider_operation?).perform
  end

  def verify_eps_bridge_session
    user = Current.user || current_user
    return unless user.is_a?(User)

    verifier = EpsBridge::SessionVerifier.new(user)
    return unless verifier.managed?

    valid = if authenticate_by_access_token?
              @eps_bridge_operation = verifier.verified_proxy_purpose(request)
            else
              verifier.active_client?(request.headers['client'], eps_requested_account)
            end
    render json: { error: 'Open Inbox2 from your active EconomyOps session' }, status: :unauthorized unless valid
  end

  def eps_requested_account
    params[:account_id] || (params[:controller] == 'api/v1/accounts' && params[:id])
  end

  def trusted_provider_operation?
    @eps_bridge_operation == 'provider-operation'
  end
end
