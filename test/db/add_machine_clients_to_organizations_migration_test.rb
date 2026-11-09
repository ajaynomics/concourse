require "test_helper"
require Rails.root.join("db/migrate/20261108150000_add_machine_clients_to_organizations")

# Runs the real migration on a scratch SQLite database: the operator's list is
# handed over once, so the organizations it named keep machine clients on
# deploy and every other organization starts with them off.
class AddMachineClientsToOrganizationsMigrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  KEY = "CONCOURSE__MACHINE_CLIENT_ORGANIZATIONS"

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @previous = ENV[KEY]
    Scratch.establish_connection(adapter: "sqlite3", database: ":memory:")
    @db = Scratch.connection
    @db.create_table(:organizations) { |t| t.string :slug }
    %w[home-agents dana stranger].each { |slug| @db.execute "INSERT INTO organizations (slug) VALUES ('#{slug}')" }
  end

  teardown do
    Scratch.remove_connection
    @previous.nil? ? ENV.delete(KEY) : ENV[KEY] = @previous
  end

  test "the organizations listed at migrate time keep machine clients and the rest start off" do
    ENV[KEY] = " home-agents, ,dana,unknown "
    migrate

    assert_equal %w[dana home-agents], enabled
  end

  test "an unset or empty list turns machine clients on nowhere" do
    [ nil, "", " , " ].each do |value|
      value.nil? ? ENV.delete(KEY) : ENV[KEY] = value
      migrate

      assert_empty enabled
      @db.remove_column :organizations, :machine_clients
    end
  end

  private
    def migrate
      ActiveRecord::Migration.suppress_messages do
        @db.transaction { AddMachineClientsToOrganizations.new.exec_migration(@db, :up) }
      end
    end

    def enabled
      @db.select_values("SELECT slug FROM organizations WHERE machine_clients ORDER BY slug")
    end
end
