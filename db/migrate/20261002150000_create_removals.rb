class CreateRemovals < ActiveRecord::Migration[8.2]
  def change
    create_table :removals do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
    add_index :removals, %i[organization_id user_id], unique: true
  end
end
