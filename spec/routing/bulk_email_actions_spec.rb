require 'rails_helper'

RSpec.describe 'Bulk email action route', type: :routing do
  it 'routes the documented conversations collection endpoint' do
    expect(post: '/api/v1/accounts/1/conversations/bulk_email_delete').to route_to(
      controller: 'api/v1/accounts/conversations/bulk_email_deletes', action: 'create', account_id: '1', format: 'json'
    )
  end
end
