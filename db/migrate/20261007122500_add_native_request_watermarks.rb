class AddNativeRequestWatermarks < ActiveRecord::Migration[8.2]
  def change
    add_column :relay_deliveries, :after_sequence, :integer, default: 0, null: false
    add_column :messages, :native_after_sequence, :integer
  end
end
