require 'rails_helper'

RSpec.describe Imap::DeleteMessagesService do
  let(:channel) do
    instance_double(
      Channel::Email,
      imap_address: 'imap.example.test', imap_port: 993, imap_enable_ssl: true,
      imap_authentication: 'plain', imap_login: 'agent@example.test', imap_password: 'synthetic-password',
      google?: false, microsoft?: false
    )
  end
  let(:imap) { instance_double(Net::IMAP) }
  let(:trash) { Net::IMAP::MailboxList.new([:'\\Trash'], '/', 'Trash') }
  let(:source_id) { 'received@example.test' }
  let(:header) { "Message-ID: <#{source_id}>\r\n\r\n" }

  before do
    allow(Net::IMAP).to receive(:new).and_return(imap)
    allow(Imap::Authentication).to receive(:authenticate!)
    allow(imap).to receive_messages(capability: %w[IMAP4REV1 MOVE UIDPLUS], list: [trash], disconnected?: false, responses: {})
    allow(imap).to receive(:select)
    allow(imap).to receive(:logout)
    allow(imap).to receive(:disconnect)
    allow(imap).to receive(:uid_search).and_return([42])
    allow(imap).to receive(:uid_fetch).and_return([Net::IMAP::FetchData.new(1, { 'UID' => 42, 'BODY[HEADER.FIELDS (MESSAGE-ID)]' => header })])
  end

  it 'moves only the exact verified UID to the provider Trash' do
    expect(imap).to receive(:uid_move).with(42, 'Trash')
    expect(imap).not_to receive(:expunge)
    expect(imap).not_to receive(:uid_expunge)

    described_class.new(channel: channel, source_ids: [source_id], locations: {}, mode: 'trash').perform
  end

  it 'moves a verified UID to the provider Junk folder for bulk spam without broad expunge' do
    allow(imap).to receive(:list).and_return([Net::IMAP::MailboxList.new([:'\\Junk'], '/', 'Junk')])
    expect(imap).to receive(:uid_move).with(42, 'Junk')
    expect(imap).not_to receive(:expunge)

    described_class.new(channel: channel, source_ids: [source_id], locations: {}, mode: 'spam').perform
  end

  it 'uses a stored UID only when UIDVALIDITY and Message-ID still match' do
    allow(imap).to receive(:responses).and_return('UIDVALIDITY' => [7])
    expect(imap).to receive(:uid_search).with(['HEADER', 'Message-ID', source_id]).once.and_return([42])
    expect(imap).to receive(:uid_move).with(42, 'Trash')

    described_class.new(
      channel: channel, source_ids: [source_id],
      locations: { source_id => { 'mailbox' => 'INBOX', 'uid' => 42, 'uid_validity' => 7 } }, mode: 'trash'
    ).perform
  end

  it 'searches again when the stored UIDVALIDITY is stale' do
    allow(imap).to receive(:responses).and_return('UIDVALIDITY' => [8])
    expect(imap).to receive(:uid_search).at_least(:once).and_return([42])
    expect(imap).to receive(:uid_move).with(42, 'Trash')

    described_class.new(
      channel: channel, source_ids: [source_id],
      locations: { source_id => { 'mailbox' => 'INBOX', 'uid' => 99, 'uid_validity' => 7 } }, mode: 'trash'
    ).perform
  end

  it 'rejects an ambiguous Message-ID without mutating the mailbox' do
    allow(imap).to receive(:uid_search).and_return([42, 43])
    allow(imap).to receive(:uid_fetch) do |uid, _fields|
      [Net::IMAP::FetchData.new(1, { 'UID' => uid, 'BODY[HEADER.FIELDS (MESSAGE-ID)]' => header })]
    end
    expect(imap).not_to receive(:uid_move)

    expect do
      described_class.new(channel: channel, source_ids: [source_id], locations: {}, mode: 'trash').perform
    end.to raise_error(described_class::Error, /ambiguous/)
  end

  it 'rejects a server without a uniquely identified Trash folder' do
    allow(imap).to receive(:list).and_return([])
    expect(imap).not_to receive(:uid_move)

    expect do
      described_class.new(channel: channel, source_ids: [source_id], locations: {}, mode: 'trash').perform
    end.to raise_error(described_class::Error, /Trash folder/)
  end

  it 'accepts an exact message already in Trash on retry' do
    selected = nil
    allow(imap).to receive(:select) { |folder| selected = folder }
    allow(imap).to receive(:uid_search) { selected == 'Trash' ? [42] : [] }
    expect(imap).not_to receive(:uid_move)

    described_class.new(channel: channel, source_ids: [source_id], locations: {}, mode: 'trash').perform
  end

  it 'rejects permanent purge without opening a provider connection' do
    expect(Net::IMAP).not_to receive(:new)
    expect do
      described_class.new(channel: channel, source_ids: [source_id], locations: {}, mode: 'permanent').perform
    end.to raise_error(described_class::Error, /Unsupported/)
  end

  it 'refuses a server without MOVE without falling back to delete or expunge' do
    allow(imap).to receive(:capability).and_return(%w[IMAP4REV1 UIDPLUS])
    expect(imap).not_to receive(:uid_store)
    expect(imap).not_to receive(:expunge)
    expect do
      described_class.new(channel: channel, source_ids: [source_id], locations: {}, mode: 'trash').perform
    end.to raise_error(described_class::Error, /UID MOVE/)
  end

  it 'reports a confirmed message only after checking its destination' do
    confirmed = []
    expect(imap).to receive(:uid_move).with(42, 'Trash')
    described_class.new(channel: channel, source_ids: [source_id], locations: {}, mode: 'trash').perform { |id| confirmed << id }
    expect(confirmed).to eq([source_id])
  end

  it 'keeps a missing destination confirmation unconfirmed' do
    selected = nil
    allow(imap).to receive(:select) { |folder| selected = folder }
    allow(imap).to receive(:uid_search) { selected == 'INBOX' ? [42] : [] }
    allow(imap).to receive(:uid_move)
    confirmed = []
    expect do
      described_class.new(channel: channel, source_ids: [source_id], locations: {}, mode: 'trash').perform { |id| confirmed << id }
    end.to raise_error(described_class::Error, /did not confirm/)
    expect(confirmed).to be_empty
  end
end
