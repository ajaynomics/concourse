class ScopeMessageIdempotencyToCaller < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :client_message_id, :string
    add_index :messages, [ :sender_agent_id, :client_message_id ],
      unique: true,
      name: "index_messages_on_sender_and_client_message_id"
  end
end
