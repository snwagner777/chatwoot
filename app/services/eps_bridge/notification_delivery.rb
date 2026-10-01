require 'net/http'
require 'openssl'
require 'base64'

class EpsBridge::NotificationDelivery
  class Unavailable < StandardError; end

  def initialize(notification)
    @notification = notification
    @user = notification.user
    @account = notification.account
    @identity = @user.custom_attributes['eps_bridge']
  end

  def perform
    return unless eligible? && authorized?

    origin = EpsBridge::SessionVerifier.application_url
    raise ArgumentError, 'Invalid EPS Core origin' unless origin

    deliver(URI.parse(origin))
  rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError
    raise Unavailable, 'EPS notification delivery was not confirmed'
  end

  private

  def eligible?
    return false unless ENV['EPS_NATIVE_NOTIFICATIONS_ENABLED'] == 'true'
    return false if @notification.read_at? || @notification.snoozed_until&.future?
    return false unless managed_identity?

    setting = @user.notification_settings.find_by(account_id: @account.id)
    setting&.public_send("push_#{@notification.notification_type}?") == true
  end

  def managed_identity?
    @account.custom_attributes['eps_managed'] == true && @identity.is_a?(Hash) &&
      @identity['account_id'] == @account.id && @identity['core_user_id'].is_a?(String)
  end

  def authorized?
    conversation = @notification.primary_actor
    return false unless conversation.is_a?(Conversation) && conversation.account_id == @account.id

    membership = @user.account_users.find_by(account_id: @account.id)
    return false unless membership && platform_authorized?

    ConversationPolicy.new({ user: @user, account: @account, account_user: membership }, conversation).show?
  end

  def platform_authorized?
    @platform = PlatformApp.find_by(id: @identity['platform_app_id'])
    return false unless @platform

    permissions = @platform.platform_app_permissibles
    permissions.exists?(permissible: @account) && permissions.exists?(permissible: @user)
  end

  def signed_request
    claims = { purpose: 'notification', timestamp: Time.current.to_i, accountId: @account.id, chatwootUserId: @user.id,
               conversationId: @notification.primary_actor.display_id, notificationId: @notification.id }
    payload = Base64.urlsafe_encode64(claims.to_json, padding: false)
    request = Net::HTTP::Post.new('/api/v1/core/internal/inbox2/notifications')
    request['content-type'] = 'text/plain; charset=utf-8'
    request['x-eps-bridge-payload'] = payload
    request['x-eps-bridge-signature'] = OpenSSL::HMAC.hexdigest('SHA256', @platform.access_token.token, payload)
    request['accept'] = 'application/json'
    request
  end

  def deliver(origin)
    Net::HTTP.start(origin.host, origin.port, use_ssl: true, open_timeout: 3, read_timeout: 3, write_timeout: 3) do |http|
      http.request(signed_request) do |response|
        # Core owns durable event deduplication. Rejections and redirects are
        # terminal; only temporary unavailability is retried with fresh claims.
        raise Unavailable, 'EPS notification delivery was not confirmed' if response.code.to_i >= 500 || response.code == '429'

        read_response(response)
      end
    end
  end

  def read_response(response)
    size = 0
    response.read_body do |chunk|
      size += chunk.bytesize
      raise Unavailable, 'EPS notification response exceeded the limit' if size > 4096
    end
  end
end
