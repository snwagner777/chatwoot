class EpsBridge::AssociateAccount
  def self.perform!(confirmation)
    raise ArgumentError, 'Explicit account association confirmation is required' unless confirmation == 'platform-app-1/account-1'

    platform_app = PlatformApp.find(1)
    account = Account.find(1)
    unless platform_app.name == 'EconomyOps Inbox2 Platform Bridge' && account.name == 'Economy Plumbing Services'
      raise ArgumentError, 'The installation resources do not match the approved account and app'
    end

    association = platform_app.platform_app_permissibles.find_or_create_by!(permissible: account)
    Rails.logger.info('EPS Inbox2 association verified: platform_app_id=1 account_id=1')
    association
  end
end
