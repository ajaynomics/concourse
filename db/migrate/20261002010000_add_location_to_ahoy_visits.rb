class AddLocationToAhoyVisits < ActiveRecord::Migration[8.1]
  def change
    add_column :ahoy_visits, :country, :string
    add_column :ahoy_visits, :region, :string
    add_column :ahoy_visits, :city, :string
    add_column :ahoy_visits, :latitude, :float
    add_column :ahoy_visits, :longitude, :float
  end
end
