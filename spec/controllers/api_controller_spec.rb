require 'rails_helper'

RSpec.describe 'API Base', type: :request do
  describe 'request to api base url' do
    it 'returns api version' do
      get '/api/'
      expect(response).to have_http_status(:success)
      expect(response.body).to include(Chatwoot.config[:version])
      expect(response.body).to include('queue_services')
      expect(response.body).to include('data_services')
      expect(response.parsed_body['eps_inbox2_bridge_version']).to eq('1.0.0')
      expect(response.parsed_body.keys.sort).to eq(%w[data_services eps_inbox2_bridge_version queue_services timestamp version])
    end
  end
end
