module EpsBridgeProfileScope
  extend ActiveSupport::Concern

  included do
    helper_method :eps_visible_account_users, :eps_visible_custom_attributes
  end

  def eps_visible_account_users(resource, account_users)
    verifier = EpsBridge::SessionVerifier.new(resource)
    account_users.select do |account_user|
      !verifier.managed_account?(account_user.account) ||
        (verifier.managed? && resource.custom_attributes['eps_bridge']['account_id'] == account_user.account_id && eps_profile_authorized?(resource))
    end
  end

  def eps_visible_custom_attributes(resource)
    return resource.custom_attributes unless resource.custom_attributes.key?('eps_bridge')
    return resource.custom_attributes if eps_profile_authorized?(resource)

    resource.custom_attributes.except('eps_bridge')
  end

  private

  def eps_profile_authorized?(resource)
    @eps_profile_authorizations ||= {}
    return @eps_profile_authorizations[resource.id] if @eps_profile_authorizations.key?(resource.id)

    @eps_profile_authorizations[resource.id] = resource == current_user && eps_profile_credential_authorized?(resource)
  end

  def eps_profile_credential_authorized?(resource)
    verifier = EpsBridge::SessionVerifier.new(resource)
    return @eps_bridge_operation.present? || verifier.verified_proxy_purpose(request).present? if request.headers['api_access_token'].present?

    client = response.headers['client'].presence || @token&.client || request.headers['client']
    verifier.active_client?(client)
  end
end
