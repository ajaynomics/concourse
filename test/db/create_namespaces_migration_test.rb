require "test_helper"
require Rails.root.join("db/migrate/20261014060000_create_namespaces")

# Runs the real migration on a scratch SQLite database shaped like production
# before it: rows that reference agents must survive adding the namespace key.
class CreateNamespacesMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    @db = Scratch.connection
    @db.create_table(:organizations) { |t| t.timestamps }
    @db.create_table(:agents) { |t| t.references :organization, foreign_key: true; t.string :handle }
    @db.create_table(:agent_client_bindings) { |t| t.references :agent, foreign_key: { on_delete: :nullify } }
    @db.create_table(:agent_connections) { |t| t.references :agent, foreign_key: { on_delete: :cascade } }
    @db.execute "INSERT INTO organizations (id, created_at, updated_at) VALUES (1, 'now', 'now')"
    @db.execute "INSERT INTO agents (id, organization_id, handle) VALUES (4, 1, 'reviews')"
    @db.execute "INSERT INTO agent_client_bindings (id, agent_id) VALUES (1, 4)"
    @db.execute "INSERT INTO agent_connections (id, agent_id) VALUES (1, 4)"
  end

  teardown { Scratch.remove_connection }

  test "adding the namespace key keeps bindings and connections" do
    @db.transaction { CreateNamespaces.new.exec_migration(@db, :up) }

    assert_equal 4, @db.select_value("SELECT agent_id FROM agent_client_bindings WHERE id = 1")
    assert_equal 1, @db.select_value("SELECT count(*) FROM agent_connections")
    assert_equal [ "namespaces" ], @db.foreign_keys(:agents).map(&:to_table) - [ "organizations" ]
    assert @db.index_exists?(:agents, %i[namespace_id handle], unique: true)
  end
end
