require 'net/imap'
require 'timeout'

class Imap::DeleteMessagesService
  class Error < StandardError; end

  pattr_initialize [:channel!, :source_ids!, :locations!, :mode!]

  def perform(&on_confirmed)
    raise Error, 'Unsupported email action' unless %w[trash spam].include?(mode)

    on_confirmed ||= ->(_source_id) {}

    Timeout.timeout(8, Error, 'The mail server did not confirm the action in time. Retry to reconcile it.') do
      @imap = Net::IMAP.new(channel.imap_address, port: channel.imap_port, ssl: channel.imap_enable_ssl, open_timeout: 5)
      authenticate!
      raise Error, 'The mail server does not support safe UID MOVE' unless @imap.capability.map(&:upcase).include?('MOVE')

      folder_type = { 'trash' => 'Trash', 'spam' => 'Junk' }.fetch(mode)
      destination = destination_mailbox(folder_type)
      raise Error, "The mail server did not identify a unique #{folder_type} folder" if destination.blank?

      move_verified_messages(destination, &on_confirmed)
    end
  ensure
    close_connection
  end

  private

  def move_verified_messages(destination)
    # Confirm one member before starting the next. An up-front scan of an entire
    # long thread can exhaust the time budget before recording any progress.
    source_ids.each do |source_id|
      @imap.select('INBOX')
      uid = exact_uid(source_id, 'INBOX')
      @imap.uid_move(uid, destination) if uid
      @imap.select(destination)
      verify_destination!(source_id, destination)
      yield source_id
    end
  end

  def verify_destination!(source_id, destination)
    return if exact_uid(source_id, destination)

    raise Error, "The provider did not confirm email message #{source_id} in #{destination}"
  end

  def close_connection
    return unless @imap

    begin
      Timeout.timeout(2) { @imap.logout unless @imap.disconnected? }
    rescue Net::IMAP::Error, IOError, SystemCallError, Timeout::Error
      nil
    ensure
      @imap.disconnect unless @imap.disconnected?
    end
  end

  def authenticate!
    mechanism, password = if channel.google?
                            ['XOAUTH2', Google::RefreshOauthTokenService.new(channel: channel).access_token]
                          elsif channel.microsoft?
                            ['XOAUTH2', Microsoft::RefreshOauthTokenService.new(channel: channel).access_token]
                          else
                            [channel.imap_authentication, channel.imap_password]
                          end
    Imap::Authentication.authenticate!(@imap, mechanism, channel.imap_login, password)
  end

  def destination_mailbox(special_use)
    folders = @imap.list('', '*') || []
    matches = folders.select { |folder| folder.attr.any? { |flag| flag.to_s.delete_prefix('\\').casecmp?(special_use) } }
    matches.one? ? matches.first.name : nil
  end

  def exact_uid(source_id, mailbox)
    stored_uid = verified_stored_uid(source_id, mailbox)
    return stored_uid if stored_uid

    uids = @imap.uid_search(['HEADER', 'Message-ID', source_id]) || []
    verified = uids.select { |uid| verified_uid?(uid, source_id) }
    raise Error, "Email message #{source_id} has an ambiguous provider match" if verified.size > 1

    verified.first
  end

  def verified_stored_uid(source_id, mailbox)
    location = locations[source_id]
    validity = @imap.responses['UIDVALIDITY']&.last
    return unless stored_location_matches?(location, mailbox, validity)

    uid = location['uid'].to_i
    uid if uid.positive? && verified_uid?(uid, source_id)
  end

  def stored_location_matches?(location, mailbox, validity)
    return false unless mailbox == 'INBOX' && location.is_a?(Hash) && validity.present?

    location['mailbox'] == mailbox && location['uid_validity'].to_i == validity.to_i
  end

  def verified_uid?(uid, source_id)
    data = @imap.uid_fetch(uid, ['UID', 'BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]'])&.first
    header = data&.attr&.fetch('BODY[HEADER.FIELDS (MESSAGE-ID)]', nil)
    data&.attr&.fetch('UID', nil) == uid && header && Mail.read_from_string(header).message_id == source_id
  end
end
