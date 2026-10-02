module EpsBridgeSso
  private

  def normalize_eps_login_email
    params[:email] = params[:email].strip.downcase if params[:email].is_a?(String)
  end

  def load_eps_sso_session
    @eps_session = @resource.eps_sso_session(params[:sso_auth_token])
    verifier = EpsBridge::SessionVerifier.new(@resource)
    return true if @eps_session.nil?
    return true if verifier.active?(@eps_session)

    render_error(:unauthorized, 'Use an active EconomyOps session to sign in')
    false
  end
end
