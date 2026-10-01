namespace :eps_bridge do
  desc 'Associate only the verified EPS account 1 with Platform Bridge app 1 after explicit operator approval'
  task associate_account: :environment do
    EpsBridge::AssociateAccount.perform!(ENV.fetch('EPS_BRIDGE_ASSOCIATION_CONFIRM', ''))
    puts 'Verified Platform Bridge app 1 access to EPS account 1. No credentials were displayed.'
  end
end
