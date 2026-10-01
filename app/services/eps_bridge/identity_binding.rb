class EpsBridge::IdentityBinding
  def initialize(platform_app, user)
    @platform_app = platform_app
    @user = user
  end

  def link!(core_user_id, account_id)
    raise ArgumentError, 'Invalid EPS member' unless valid_member?(core_user_id, account_id)

    identity = { 'core_user_id' => core_user_id, 'account_id' => account_id, 'platform_app_id' => @platform_app.id }
    existing = @user.custom_attributes['eps_bridge']
    raise ArgumentError, 'The EPS identity is already bound' if existing.present? && existing != identity

    @user.update!(custom_attributes: @user.custom_attributes.merge('eps_bridge' => identity))
    account = Account.find(account_id)
    account.update!(custom_attributes: account.custom_attributes.merge('eps_managed' => true))
    { core_user_id: core_user_id, account_id: account_id, user_id: @user.id }
  end

  def login_binding(params)
    return unless @user.custom_attributes.key?('eps_bridge')

    identity = @user.custom_attributes['eps_bridge']
    raise ArgumentError, 'Invalid EPS session binding' unless matching_login?(identity, params)

    { 'core_user_id' => identity['core_user_id'], 'web_session_id' => params[:eps_session_id], 'account_id' => identity['account_id'] }
  end

  private

  def valid_member?(core_user_id, account_id)
    core_user_id.is_a?(String) && core_user_id.length.between?(1, 200) &&
      @user.account_users.exists?(account_id: account_id) &&
      @platform_app.platform_app_permissibles.exists?(permissible_type: 'Account', permissible_id: account_id)
  end

  def matching_login?(identity, params)
    identity['platform_app_id'] == @platform_app.id && identity['core_user_id'] == params[:eps_core_user_id] &&
      identity['account_id'].to_s == params[:eps_account_id].to_s && params[:eps_session_id].is_a?(String) &&
      params[:eps_session_id].length.between?(1, 200)
  end
end
