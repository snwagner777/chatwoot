require 'rails_helper'

RSpec.describe Conversations::BulkEmailDeleteService do
  let(:request_id) { SecureRandom.uuid }
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox).reload }
  let(:user) { create(:user, account: account, role: :administrator) }
  let!(:received_message) do
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: 'received@example.test')
  end
  let(:provider) { instance_double(Imap::DeleteMessagesService) }
  let(:tracker) { instance_double(Imap::DeletedMessageTracker, record: true) }

  before do
    allow(Imap::DeleteMessagesService).to receive(:new).and_return(provider)
    allow(Imap::DeletedMessageTracker).to receive(:new).with(inbox: channel.inbox).and_return(tracker)
  end

  it 'removes the local conversation synchronously only after provider confirmation' do
    allow(provider).to receive(:perform) { |&callback|
      expect(Conversation.exists?(conversation.id)).to be true
      callback.call(received_message.source_id)
    }

    described_class.new(conversation: conversation, user: user, request_id: request_id, ip: '127.0.0.1', mode: 'trash').perform

    expect(Conversation.exists?(conversation.id)).to be false
    expect(tracker).to have_received(:record).with([received_message.source_id])
    expect(DeleteObjectJob).not_to have_been_enqueued
    expect(EmailActionReceipt.find_by!(request_id: request_id).result).to eq('deleted' => true)
  end

  it 'persists confirmed per-message outcomes on a partial provider failure' do
    allow(provider).to receive(:perform) do |&callback|
      callback.call(received_message.source_id)
      raise Imap::DeleteMessagesService::Error, 'provider interrupted'
    end
    expect do
      described_class.new(conversation: conversation, user: user, request_id: request_id, mode: 'trash').perform
    end.to raise_error(Imap::DeleteMessagesService::Error)
    receipt = EmailActionReceipt.find_by!(request_id: request_id)
    expect(receipt.confirmed_source_ids).to eq([received_message.source_id])
    expect(receipt.message_ids).to include(received_message.id)
  end

  it 'retains the local thread and records no deletion when the provider fails' do
    allow(provider).to receive(:perform).and_raise(Imap::DeleteMessagesService::Error, 'provider rejected move')

    expect do
      described_class.new(conversation: conversation, user: user, request_id: request_id, mode: 'trash').perform
    end.to raise_error(Imap::DeleteMessagesService::Error)

    expect(Conversation.exists?(conversation.id)).to be true
    expect(tracker).not_to have_received(:record)
  end

  it 'marks spam without deleting the conversation, messages or existing labels' do
    conversation.update!(label_list: ['important'])
    allow(provider).to receive(:perform).and_yield(received_message.source_id)

    described_class.new(conversation: conversation, user: user, request_id: request_id, mode: 'spam').perform

    expect(conversation.reload).to be_resolved
    expect(conversation.label_list).to contain_exactly('important', 'spam')
    expect(Message.exists?(received_message.id)).to be true
    expect(tracker).not_to have_received(:record)
  end

  %w[incoming outgoing].each do |message_type|
    it "retains new #{message_type} messages arriving while provider work is in progress" do
      allow(provider).to receive(:perform) do
        create(:message, account: account, inbox: channel.inbox, conversation: conversation,
                         message_type: message_type, source_id: "new-#{message_type}@example.test")
      end

      expect do
        described_class.new(conversation: conversation, user: user, request_id: request_id, mode: 'trash').perform
      end.to raise_error(described_class::Error, /new activity/i)

      expect(Conversation.exists?(conversation.id)).to be true
      expect(conversation.messages.where(source_id: "new-#{message_type}@example.test")).to exist
      expect(tracker).not_to have_received(:record)
    end
  end
  it 'does not expand the persisted snapshot when the same action is retried after new activity' do
    allow(provider).to receive(:perform).and_raise(Imap::DeleteMessagesService::Error, 'temporary failure')
    expect do
      described_class.new(conversation: conversation, user: user, request_id: request_id, mode: 'trash').perform
    end.to raise_error(Imap::DeleteMessagesService::Error)
    create(:message, account: account, conversation: conversation, inbox: channel.inbox, source_id: 'later@example.test')
    expect(provider).not_to receive(:perform)

    expect do
      described_class.new(conversation: conversation, user: user, request_id: request_id, mode: 'trash').perform
    end.to raise_error(described_class::Error, /New activity/)
    expect(EmailActionReceipt.find_by!(request_id: request_id).source_ids).to eq([received_message.source_id])
  end

  it 'makes monotonic durable progress across bounded retries for a large already-moved thread' do
    29.times do |index|
      create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: "retry-#{index}@example.test")
    end
    source_ids = conversation.messages.incoming.reorder(:id).pluck(:source_id)
    imap = instance_double(Net::IMAP)
    selected_folder = nil
    command_count = 0
    allow(Imap::DeleteMessagesService).to receive(:new).and_call_original
    allow(Net::IMAP).to receive(:new) {
      command_count = 0
      imap
    }
    allow(Imap::Authentication).to receive(:authenticate!)
    allow(imap).to receive_messages(capability: ['MOVE'], list: [Net::IMAP::MailboxList.new([:Trash], '/', 'Trash')],
                                    responses: {}, disconnected?: false, logout: true, disconnect: true)
    allow(imap).to receive(:select) { |folder| selected_folder = folder }
    allow(imap).to receive(:uid_search) do |query|
      command_count += 1
      raise Imap::DeleteMessagesService::Error, 'synthetic command budget reached' if command_count > 7

      selected_folder == 'INBOX' ? [] : [source_ids.index(query.last) + 1]
    end
    allow(imap).to receive(:uid_fetch) do |uid, _fields|
      [Net::IMAP::FetchData.new(1, 'UID' => uid, 'BODY[HEADER.FIELDS (MESSAGE-ID)]' => "Message-ID: <#{source_ids.fetch(uid - 1)}>\r\n\r\n")]
    end
    confirmed_count = 0
    10.times do
      begin
        described_class.new(conversation: conversation, user: user, request_id: request_id, mode: 'trash').perform
      rescue Imap::DeleteMessagesService::Error
        # A bounded attempt commits its progress and can be resumed.
      end
      receipt = EmailActionReceipt.find_by!(request_id: request_id)
      expect(receipt.confirmed_source_ids.length).to be > confirmed_count
      confirmed_count = receipt.confirmed_source_ids.length
      break if receipt.completed?
    end
    expect(confirmed_count).to eq(30)
    expect(Conversation.exists?(conversation.id)).to be false
  end
end
