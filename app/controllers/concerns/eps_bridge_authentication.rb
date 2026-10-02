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
    account_id = eps_requested_account
    return unless verifier.managed_account?(account_id)

    valid = if authenticate_by_access_token?
              @eps_bridge_operation = verifier.verified_proxy_purpose(request, account_id)
            else
              verifier.active_client?(request.headers['client'], account_id)
            end
    render json: { error: 'Open Inbox2 from your active EconomyOps session' }, status: :unauthorized unless valid
  end

  def eps_requested_account
    return request.path_parameters[:id] if %w[api/v1/accounts enterprise/api/v1/accounts].include?(controller_path)
    if controller_path == 'api/v1/profiles' && %w[availability auto_offline set_active_account].include?(action_name)
      return params.dig(:profile, :account_id)
    end

    request.path_parameters[:account_id]
  end

  def trusted_provider_operation?
    @eps_bridge_operation == 'provider-operation'
  end
end
