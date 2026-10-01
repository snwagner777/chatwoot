module EpsBridgeSso
  private

  def eps_login_method_allowed?
    user = User.from_email(params[:email]) if params[:email].present?
    return true unless user&.custom_attributes&.key?('eps_bridge')
    return true if sso_authentication_request?

    render_error(:unauthorized, 'Use EconomyOps to sign in')
    false
  end

  def load_eps_sso_session
    @eps_session = @resource.eps_sso_session(params[:sso_auth_token])
    verifier = EpsBridge::SessionVerifier.new(@resource)
    return true unless verifier.managed?
    return true if verifier.active?(@eps_session)

    render_error(:unauthorized, 'Use an active EconomyOps session to sign in')
    false
  end
end
