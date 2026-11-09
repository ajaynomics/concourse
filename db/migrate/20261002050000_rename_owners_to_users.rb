# The person is a user of Concourse. "Owner" stays for what it means in the
# domain: the person who owns an agent, or the owner role in an organization.
class RenameOwnersToUsers < ActiveRecord::Migration[8.2]
  def change
    rename_table :owners, :users
    rename_column :push_subscriptions, :owner_id, :user_id
  end
end
