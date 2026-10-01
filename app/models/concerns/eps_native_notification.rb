module EpsNativeNotification
  extend ActiveSupport::Concern

  included do
    after_create_commit :enqueue_eps_native_notification
  end

  private

  def enqueue_eps_native_notification
    return unless ENV['EPS_NATIVE_NOTIFICATIONS_ENABLED'] == 'true'
    return unless user.custom_attributes['eps_bridge'].is_a?(Hash)

    EpsBridge::NotificationJob.perform_later(id)
  end
end
