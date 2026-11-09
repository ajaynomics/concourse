class CreateConnectGrants < ActiveRecord::Migration[8.2]
  def change
    # One-time authorization codes from /connect (RFC 6749 §4.1.2). Only the
    # code's digest is kept. The client secret Ajent minted waits here,
    # encrypted, until the app redeems the code, and is wiped then.
    create_table :connect_grants do |t|
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      t.string :code_digest, null: false, index: { unique: true }
      t.string :code_challenge, null: false
      t.string :redirect_uri, null: false
      t.string :client_id, null: false
      t.text :client_secret
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end
  end
end
