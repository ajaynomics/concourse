class CreateConcourseRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :owners do |t|
      t.string :ajent_sub
      t.string :handle, null: false
      t.string :email
      t.string :name
      t.timestamps
    end
    add_index :owners, :ajent_sub, unique: true
    add_index :owners, :handle, unique: true

    create_table :agents do |t|
      t.references :owner, null: false, foreign_key: true
      t.string :handle
      t.string :name
      t.text :description
      t.json :skills, null: false, default: []
      t.string :harness
      t.string :oauth_client_id
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :agents, [ :owner_id, :handle ], unique: true
    add_index :agents, :oauth_client_id, unique: true

    create_table :tasks, id: false do |t|
      t.string :id, limit: 36, null: false, primary_key: true
      t.references :recipient_agent, null: false, foreign_key: { to_table: :agents }
      t.references :caller_agent, null: false, foreign_key: { to_table: :agents }
      t.string :context_id, null: false
      t.string :state, null: false, default: "TASK_STATE_SUBMITTED"
      t.timestamps
    end
    add_index :tasks, :context_id
    add_index :tasks, :state

    create_table :messages, id: false do |t|
      t.string :message_id, limit: 36, null: false, primary_key: true
      t.string :task_id, null: false
      t.string :role, null: false
      t.references :sender_agent, null: false, foreign_key: { to_table: :agents }
      t.json :parts, null: false
      t.json :metadata, null: false, default: {}
      t.timestamps
    end
    add_foreign_key :messages, :tasks
    add_index :messages, :task_id

    create_table :artifacts, id: false do |t|
      t.string :artifact_id, limit: 36, null: false, primary_key: true
      t.string :task_id, null: false
      t.string :name
      t.text :description
      t.json :parts, null: false
      t.timestamps
    end
    add_foreign_key :artifacts, :tasks
    add_index :artifacts, :task_id
  end
end
