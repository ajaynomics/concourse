class RemoveSearchFromAgents < ActiveRecord::Migration[8.1]
  def change
    remove_column :agents, :search_text, :text
    remove_column :agents, :embedding, :json, default: []
    remove_column :agents, :embedding_model, :string
    remove_column :agents, :embedded_at, :datetime
  end
end
