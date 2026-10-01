require 'rails_helper'

RSpec.describe Message do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_api, account: account, additional_attributes: { provider_delivery_tracking: true }) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }

  it 'starts an external API reply pending without claiming provider acceptance' do
    message = create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing)
    expect(message.reload.status).to eq('pending')
    expect(message.provider_delivery_tracking?).to be true
  end

  it 'keeps private notes and existing accepted provider echoes unchanged' do
    note = create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing, private: true)
    echo = create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing, source_id: 'provider-id')
    expect(note.status).to eq('sent')
    expect(echo.status).to eq('sent')
  end

  it 'leaves ordinary API inbox behavior unchanged' do
    channel.update!(additional_attributes: {})
    message = create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing)
    expect(message.status).to eq('sent')
  end

  it 'allows pending and unknown outcomes to reconcile but rejects late accepted events' do
    message = create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing)
    expect(Messages::StatusUpdateService.new(message, 'delivery_unknown').perform).to be_truthy
    expect(message.reload.status).to eq('delivery_unknown')
    expect(Messages::StatusUpdateService.new(message, 'sent').perform).to be_truthy
    expect(Messages::StatusUpdateService.new(message, 'delivered').perform).to be_truthy
    expect(Messages::StatusUpdateService.new(message, 'sent').perform).to be false
    expect(Messages::StatusUpdateService.new(message, 'failed').perform).to be false
    expect(message.reload.status).to eq('delivered')
  end

  it 'does not revive a terminal failure on a replayed accepted event' do
    message = create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing)
    expect(Messages::StatusUpdateService.new(message, 'failed', 'Rejected').perform).to be_truthy
    expect(Messages::StatusUpdateService.new(message, 'sent').perform).to be false
    expect(message.reload.status).to eq('failed')
  end
end
