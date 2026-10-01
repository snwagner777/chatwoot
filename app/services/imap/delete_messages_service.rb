require 'net/imap'

class Imap::DeleteMessagesService
  class Error < StandardError; end

  pattr_initialize [:channel!, :source_ids!, :locations!, :mode!]

  def perform
    raise Error, 'Unsupported deletion mode' unless %w[trash spam permanent].include?(mode)

    imap = Net::IMAP.new(channel.imap_address, port: channel.imap_port, ssl: channel.imap_enable_ssl)
    authenticate!(imap)
    capabilities = imap.capability.map(&:upcase)
    raise Error, 'The mail server does not support safe UID MOVE' if mode != 'permanent' && !capabilities.include?('MOVE')
    raise Error, 'The mail server does not support safe UID EXPUNGE' if mode == 'permanent' && !capabilities.include?('UIDPLUS')

    destination = destination_mailbox(imap, mode == 'spam' ? 'Junk' : 'Trash') unless mode == 'permanent'
    raise Error, "The mail server did not identify a unique #{mode == 'spam' ? 'Junk' : 'Trash'} folder" if mode != 'permanent' && destination.blank?

    imap.select('INBOX')
    # UIDs are resolved in this selected mailbox, so a stale UIDVALIDITY cannot target another message.
    matches = source_ids.index_with { |source_id| exact_uid(imap, source_id, 'INBOX') }
    if mode != 'permanent'
      # A retry can continue when an earlier request moved a message but did not finish the conversation.
      missing = matches.select { |_source_id, uid| uid.nil? }.keys
      if missing.any?
        imap.select(destination)
        missing.each do |source_id|
          raise Error, "Email message #{source_id} is missing from Inbox and #{destination}" unless exact_uid(imap, source_id, destination)
        end
        imap.select('INBOX')
        matches = source_ids.index_with { |source_id| exact_uid(imap, source_id, 'INBOX') }
      end
    elsif matches.value?(nil)
      raise Error, 'A received message is missing from the provider Inbox'
    end

    matches.each_value do |uid|
      next unless uid

      if mode != 'permanent'
        imap.uid_move(uid, destination)
      else
        imap.uid_store(uid, '+FLAGS.SILENT', [:Deleted])
        imap.uid_expunge(uid)
      end
    end
  ensure
    if imap
      begin
        imap.logout unless imap.disconnected?
      rescue Net::IMAP::Error
        nil
      ensure
        imap.disconnect unless imap.disconnected?
      end
    end
  end

  private

  def authenticate!(imap)
    mechanism, password = if channel.google?
                            ['XOAUTH2', Google::RefreshOauthTokenService.new(channel: channel).access_token]
                          elsif channel.microsoft?
                            ['XOAUTH2', Microsoft::RefreshOauthTokenService.new(channel: channel).access_token]
                          else
                            [channel.imap_authentication, channel.imap_password]
                          end
    Imap::Authentication.authenticate!(imap, mechanism, channel.imap_login, password)
  end

  def destination_mailbox(imap, special_use)
    folders = imap.list('', '*') || []
    matches = folders.select { |folder| folder.attr.any? { |flag| flag.to_s.delete_prefix('\\').casecmp?(special_use) } }
    matches.one? ? matches.first.name : nil
  end

  def exact_uid(imap, source_id, mailbox)
    location = locations[source_id]
    validity = imap.responses['UIDVALIDITY']&.last
    if mailbox == 'INBOX' && location.is_a?(Hash) && location['mailbox'] == mailbox &&
       location['uid_validity'].to_i == validity.to_i && validity.present?
      uid = location['uid'].to_i
      return uid if uid.positive? && verified_uid?(imap, uid, source_id)
    end

    uids = imap.uid_search(['HEADER', 'Message-ID', source_id]) || []
    verified = uids.select { |uid| verified_uid?(imap, uid, source_id) }
    raise Error, "Email message #{source_id} has an ambiguous provider match" if verified.size > 1

    verified.first
  end

  def verified_uid?(imap, uid, source_id)
    data = imap.uid_fetch(uid, ['UID', 'BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]'])&.first
    header = data&.attr&.fetch('BODY[HEADER.FIELDS (MESSAGE-ID)]', nil)
    data&.attr&.fetch('UID', nil) == uid && header && Mail.read_from_string(header).message_id == source_id
  end
end
