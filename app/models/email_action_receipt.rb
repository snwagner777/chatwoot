class EmailActionReceipt < ApplicationRecord
  belongs_to :account
  belongs_to :user

  validates :request_id, :conversation_record_id, :conversation_display_id, presence: true
  validates :mode, inclusion: { in: %w[trash spam] }

  def completed?
    result['deleted'] == true || result['spam'] == true
  end
end
