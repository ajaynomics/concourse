class AddNativeSnapshotOrder < ActiveRecord::Migration[8.2]
  def change
    add_column :messages, :native_position, :integer
    add_column :artifacts, :native_position, :integer
  end
end
