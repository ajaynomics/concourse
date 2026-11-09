class AddEmailVerifiedToUsers < ActiveRecord::Migration[8.2]
  # False until the person next signs in on the web, which is when the
  # identity provider vouches for the address again.
  def change
    add_column :users, :email_verified, :boolean, default: false, null: false
  end
end
