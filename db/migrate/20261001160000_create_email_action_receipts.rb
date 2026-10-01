class CreateEmailActionReceipts < ActiveRecord::Migration[7.1]
  def change
    create_table :email_action_receipts do |t|
      t.bigint :account_id, null: false
      t.bigint :user_id, null: false
      t.bigint :conversation_record_id, null: false
      t.integer :conversation_display_id, null: false
      t.string :request_id, null: false
      t.string :mode, null: false
      t.jsonb :message_ids, null: false, default: []
      t.jsonb :source_ids, null: false, default: []
      t.jsonb :locations, null: false, default: {}
      t.jsonb :confirmed_source_ids, null: false, default: []
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_index :email_action_receipts, [:account_id, :request_id, :conversation_display_id], unique: true,
                                                                                            name: 'index_email_action_receipts_on_request'
  end
end
