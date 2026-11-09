class CreatePushSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :push_subscriptions do |t|
      t.references :owner, null: false, foreign_key: { on_delete: :cascade }
      t.string :endpoint, null: false
      t.string :p256dh_key, null: false
      t.string :auth_key, null: false
      t.timestamps
    end
    add_index :push_subscriptions, :endpoint, unique: true
  end
end
