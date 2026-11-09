class AddProvenanceToAgentClientBindings < ActiveRecord::Migration[8.2]
  def change
    # operator: bound by hand after inspecting the issuer. connect: minted by
    # Ajent when a signed-in member approved an app at /connect, so retiring
    # it also asks Ajent to revoke the client.
    add_column :agent_client_bindings, :provenance, :string, null: false, default: "operator"
  end
end
