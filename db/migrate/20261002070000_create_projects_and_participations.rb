class CreateProjectsAndParticipations < ActiveRecord::Migration[8.2]
  def change
    create_table :projects do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :slug, null: false
      t.string :name, null: false
      t.text :description
      t.timestamps
    end
    add_index :projects, %i[organization_id slug], unique: true

    create_table :participations do |t|
      t.references :project, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :participations, %i[project_id agent_id], unique: true
  end
end
