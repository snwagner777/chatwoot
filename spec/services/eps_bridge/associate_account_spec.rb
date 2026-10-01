require 'rails_helper'

RSpec.describe EpsBridge::AssociateAccount do
  it 'requires explicit confirmation and exact resource names, then is idempotent' do
    account = create(:account, id: 1, name: 'Economy Plumbing Services')
    platform_app = create(:platform_app, id: 1, name: 'EconomyOps Inbox2 Platform Bridge')
    expect { described_class.perform!('') }.to raise_error(ArgumentError)
    expect { described_class.perform!('platform-app-1/account-1') }.to change(PlatformAppPermissible, :count).by(1)
    expect { described_class.perform!('platform-app-1/account-1') }.not_to change(PlatformAppPermissible, :count)
    expect(platform_app.platform_app_permissibles.exists?(permissible: account)).to be true
  end

  it 'does not grant a different account or app that reused these IDs' do
    create(:account, id: 1, name: 'Different account')
    create(:platform_app, id: 1, name: 'EconomyOps Inbox2 Platform Bridge')
    expect { described_class.perform!('platform-app-1/account-1') }.to raise_error(ArgumentError)
    expect(PlatformAppPermissible.count).to eq(0)
  end
end
