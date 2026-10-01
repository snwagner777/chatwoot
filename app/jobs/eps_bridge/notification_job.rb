class EpsBridge::NotificationJob < ApplicationJob
  queue_as :default
  retry_on EpsBridge::NotificationDelivery::Unavailable, wait: :polynomially_longer, attempts: 5 do
    Rails.logger.warn('EPS native notification delivery exhausted retries')
  end

  def perform(notification_id)
    notification = Notification.find_by(id: notification_id)
    return unless notification

    EpsBridge::NotificationDelivery.new(notification).perform
  end
end
