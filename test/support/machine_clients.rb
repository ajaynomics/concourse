module MachineClients
  def setup_machine_client
    @machine_settings = Rails.application.config.x.concourse
    @previous_legacy_org = @machine_settings.legacy_organization
    @organization = Organization.create!(name: "Machine Lab", slug: "machine-lab", machine_clients: true)
    @owner = User.create!(ajent_sub: "machine-owner", handle: "machine-owner", organizations: [ @organization ])
    @agent = @owner.agents.create!(handle: "worker", organization: @organization, oauth_client_id: "human-profile")
    @binding = Agent::ClientBinding.bind!(agent: @agent, client_id: "machine-client", verified_owner_sub: @owner.ajent_sub)
    @payload = {
      "active" => true, "scope" => "concourse", "client_id" => @binding.client_id,
      "aud" => Concourse.app_url, "exp" => 1.hour.from_now.to_i, "iat" => Time.current.to_i, "token_type" => "Bearer"
    }
  end

  def restore_machine_settings
    @machine_settings.legacy_organization = @previous_legacy_org
  end

  def stub_machine(payload = @payload, token: "machine-token")
    stub_request(:post, AgentTokens::INTROSPECT).with(body: hash_including("token" => token)).to_return(
      status: 200, body: payload.to_json, headers: { "Content-Type" => "application/json" }
    )
  end
end
