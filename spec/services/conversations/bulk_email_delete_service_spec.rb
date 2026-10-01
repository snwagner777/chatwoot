require 'rails_helper'

RSpec.describe Conversations::BulkEmailDeleteService do
  let(:channel) { instance_double(Channel::Email, imap_enabled?: true, reauthorization_required?: false) }
  let(:inbox) { double('email inbox', channel: channel) }
  let(:messages) { double('received messages') }
  let(:received_message) { double('received message', source_id: 'first@example.test', content_attributes: {}) }
  let(:conversation) { double('conversation', id: 8, inbox_id: 3, inbox: inbox, messages: messages) }
  let(:user) { double('administrator', id: 2) }
  let(:provider) { instance_double(Imap::DeleteMessagesService) }
  let(:local_delete) { instance_double(Conversations::DeleteService) }

  before do
    allow(messages).to receive(:incoming).and_return(messages)
    allow(messages).to receive(:select).with(:source_id, :content_attributes).and_return([received_message])
    allow(Imap::DeleteMessagesService).to receive(:new).and_return(provider)
    allow(Conversations::DeleteService).to receive(:new).and_return(local_delete)
  end

  it 'removes the Chatwoot conversation only after provider confirmation' do
    expect(provider).to receive(:perform).ordered
    expect(local_delete).to receive(:perform).ordered

    described_class.new(conversation: conversation, user: user, ip: '127.0.0.1', mode: 'trash').perform
  end

  it 'leaves the Chatwoot conversation visible when provider deletion fails' do
    allow(provider).to receive(:perform).and_raise(Imap::DeleteMessagesService::Error, 'provider rejected move')
    expect(local_delete).not_to receive(:perform)

    expect do
      described_class.new(conversation: conversation, user: user, ip: '127.0.0.1', mode: 'trash').perform
    end.to raise_error(Imap::DeleteMessagesService::Error)
  end
end
