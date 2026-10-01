module ProviderDeliveryTracking
  extend ActiveSupport::Concern

  included do
    before_validation :initialize_provider_delivery_status, on: :create
  end

  def provider_delivery_tracking?
    inbox&.api? && inbox.channel.additional_attributes['provider_delivery_tracking'] == true
  end

  private

  def initialize_provider_delivery_status
    return unless provider_delivery_tracking? && outgoing? && !private? && source_id.blank? && sent?

    self.status = :pending
  end
end
