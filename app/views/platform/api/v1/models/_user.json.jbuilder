verifier = EpsBridge::SessionVerifier.new(resource)
permitted_account_ids = @platform_app.platform_app_permissibles.where(permissible_type: 'Account').pluck(:permissible_id)
account_users = resource.account_users.includes(:account).select do |membership|
  !verifier.managed_account?(membership.account) || permitted_account_ids.include?(membership.account_id)
end
active_account_user = account_users.max_by { |membership| [membership.active_at ? 1 : 0, membership.active_at || Time.at(0).utc] }
identity = resource.custom_attributes['eps_bridge']
custom_attributes = if identity.is_a?(Hash) && permitted_account_ids.include?(identity['account_id'])
                      resource.custom_attributes
                    else
                      resource.custom_attributes.except('eps_bridge')
                    end

json.access_token resource.access_token.token
json.account_id active_account_user&.account_id
json.available_name resource.available_name
json.avatar_url resource.avatar_url
json.confirmed resource.confirmed?
json.display_name resource.display_name
json.message_signature resource.message_signature
json.email resource.email
json.id resource.id
json.name resource.name
json.provider resource.provider
json.pubsub_token resource.pubsub_token
json.custom_attributes custom_attributes if resource.custom_attributes.present?
json.role active_account_user&.role
json.ui_settings resource.ui_settings
json.uid resource.uid
json.accounts do
  json.array! account_users do |account_user|
    json.id account_user.account_id
    json.name account_user.account.name
    json.active_at account_user.active_at
    json.role account_user.role
  end
end
