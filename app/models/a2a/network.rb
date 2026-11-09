module A2a
  # Deterministic application skills, not new A2A methods or a content
  # interpreter. Direct Message results preserve the union in §3.1.1.
  class Network
    SKILLS = %w[presence delivery].map do |operation|
      { "id" => "concourse.#{operation}", "name" => "Concourse #{operation}",
        "description" => "Authenticated organization-scoped #{operation} observation. Not executor readiness or completion.",
        "tags" => [ "network", operation ], "inputModes" => [ "application/json" ], "outputModes" => [ "application/json" ] }
    end.freeze

    def self.handle(organization)
      "#{User::SYSTEM_HANDLE}/network-#{organization.id}"
    end

    def self.agent?(agent)
      agent.owner.system? && agent.qualified_handle == handle(agent.organization)
    end

    def self.ensure!(organization)
      organization.with_lock do
        owner = User.system
        organization.memberships.find_or_create_by!(user: owner)
        agent = organization.agents.find_or_initialize_by(owner: owner, handle: "network-#{organization.id}")
        agent.assign_attributes(name: "Concourse network", description: "Model-free presence and requested delivery observations.", skills: SKILLS, harness: "none")
        agent.save!
        agent
      end
    end

    def self.deliver(task)
      message = task.messages.where(role: "ROLE_USER").order(created_at: :desc, message_id: :desc).first
      parts = message.parts
      raise Error.new(:invalid_params) unless parts.size == 1 && parts.first["mediaType"] == "application/json" && parts.first["data"].is_a?(Hash)

      data = new(task.caller_agent).query(parts.first["data"].stringify_keys)
      payload = { "messageId" => SecureRandom.uuid, "role" => "ROLE_AGENT", "contextId" => task.context_id,
        "parts" => [ { "mediaType" => "application/json", "data" => data } ] }
      task.destroy!
      DirectMessage.new(payload: payload)
    end

    def initialize(caller)
      @caller = caller
    end

    def query(data)
      raise Error.new(:task_not_found) unless @caller.admitted?
      case data["operation"]
      when "presence"
        validate_keys!(data, %w[operation agent])
        agent = recipient(data["agent"])
        Agent::Connection.presence(agent).merge("operation" => "presence", "agent" => agent.qualified_handle)
      when "delivery"
        validate_keys!(data, %w[operation taskId messageId recipient])
        delivery(data).merge("operation" => "delivery")
      else
        raise Error.new(:invalid_params)
      end
    end

    private

    def validate_keys!(data, keys)
      raise Error.new(:invalid_params) unless (data.keys - keys).empty?
    end

    # Membership/tenant visibility precedes lookup (§13.1). The caller cannot
    # probe another tenant's receipt fences even after moving organizations.
    def recipient(handle)
      raise Error.new(:invalid_params) unless handle.is_a?(String) && handle.split("/").size == 2
      owner, name = handle.split("/")
      agent = @caller.organization.agents.named(owner, name)
      raise Error.new(:task_not_found) unless agent
      agent
    end

    def delivery(data)
      if data["taskId"]
        raise Error.new(:invalid_params) unless data["taskId"].is_a?(String) && data["taskId"].present? && !data.key?("recipient")
        task = Task.visible_to(@caller).find_by(id: data["taskId"])
        raise Error.new(:task_not_found) unless task && task.participants_admitted?
        message = caller_message(task, data["messageId"]) if data.key?("messageId")
        return { "state" => "absent", "accepted" => false } if data.key?("messageId") && !message
        TaskDelivery.receipt(task, message_id: message&.message_id)
      else
        agent = recipient(data["recipient"])
        id = data["messageId"]
        raise Error.new(:invalid_params) unless id.is_a?(String) && id.present?
        receipt = @caller.organization.relay_deliveries.where(caller_agent_id: @caller.id, recipient_agent_id: agent.id,
          message_id_digest: Digest::SHA256.hexdigest(id), operation: "SendMessage").first
        return { "state" => "absent", "accepted" => false } unless receipt
        return { "state" => "expired", "accepted" => true } if receipt.expired_at?
        if receipt.task_id
          task = Task.visible_to(@caller).find_by(id: receipt.task_id)
          raise Error.new(:task_not_found) unless task && task.participants_admitted?
          message = caller_message(task, id)
          raise Error.new(:task_not_found) unless message
          TaskDelivery.receipt(task, message_id: message.message_id)
        elsif receipt.phase == "accepted" && receipt.result_payload&.key?("message")
          { "state" => "delivered", "accepted" => true, "resultType" => "message", "taskStatus" => nil }
        else
          { "state" => "uncertain", "accepted" => receipt.phase == "accepted", "taskStatus" => nil }
        end
      end
    end

    def caller_message(task, id)
      raise Error.new(:invalid_params) unless id.is_a?(String) && id.present?
      task.messages.where(role: "ROLE_USER", sender_agent_id: task.caller_agent_id).detect { |message| message.wire_message_id == id }
    end
  end
end
