class CreatePushConfigs < ActiveRecord::Migration[8.2]
  def change
    # One webhook per agent. The token is encrypted by Active Record, so the
    # column holds ciphertext, which is longer than the token itself.
    create_table :push_configs do |t|
      t.references :agent, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.string :url, null: false, limit: 2048
      t.text :token, null: false
      t.timestamps
    end
  end
end
