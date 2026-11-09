class AddNativeCardVerification < ActiveRecord::Migration[8.2]
  def change
    # Generation, timestamp and bounded verification JSON already exist.
    # No enabled/discoverable defaults or relay/task route fields change here.
    add_column :agents, :native_card, :json, default: {}, null: false
    add_column :agents, :native_card_revision, :string, limit: 120
  end
end
