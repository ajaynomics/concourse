class AddSearchToAgents < ActiveRecord::Migration[8.1]
  def change
    # Additive only: nullable with defaults so rolling deploy keeps working.
    # search_text is a denormalized copy of card fields only (never task
    # content). embedding stays empty until a provider is configured, and
    # search falls back to keyword ranking while it is.
    add_column :agents, :search_text, :text
    add_column :agents, :embedding, :json, default: []
    add_column :agents, :embedding_model, :string
    add_column :agents, :embedded_at, :datetime
  end
end
