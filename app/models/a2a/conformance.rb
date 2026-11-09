module A2a
  # concourse/conformance, owned by the system user and kept in the default
  # organization, the platform's own, where the un-prefixed endpoint finds
  # it. A deterministic
  # responder for the A2A TCK: no model, and no work for any other agent.
  #
  # The messageId prefix is the TCK's in-band signal
  # (scenarios/core_operations.feature). SendMessage settles the task before
  # it returns, in both execution modes, because the TCK reads that response
  # and does not wait for a job (§3.2.2's "still in progress" clause does
  # not apply once the work has finished). A streaming message settles the
  # same way, so its stream is the finished task; the prefixes of
  # scenarios/streaming.feature, which script events after the stream opens,
  # are answered like any other message.
  class Conformance
    HANDLE = "conformance"
    # The reference SUT uses these bytes. The TCK checks filename and
    # mediaType, not the bytes.
    FILE_BYTES = Base64.strict_encode64("tck")
    FILE_NAME = "output.txt"
    FILE_TYPE = "text/plain"
    FILE_URL = "https://example.com/output.txt"
    DATA = { "key" => "value", "count" => 42 }.freeze
    HELLO = "Hello from TCK"
    REJECTED_TEXT = "rejected"
    DIRECT_TEXT = "Direct message response"
    TEXT_ARTIFACT = "Generated text content"
    SKILL = {
      "id" => "tck",
      "name" => "TCK conformance",
      "description" => "Handles A2A TCK messages selected by messageId prefix.",
      "tags" => [ "tck" ],
      "examples" => [ "tck-complete-task" ],
      "inputModes" => Card::MODES,
      "outputModes" => Card::MODES
    }.freeze

    # Compatibility for the deterministic responder; Messages are not TCK-only.
    DirectMessage = A2a::DirectMessage

    def self.ensure!
      organization = Organization.default
      owner = User.system
      organization.memberships.find_or_create_by!(user: owner)
      agent = owner.agents.find_or_initialize_by(handle: HANDLE)
      agent.organization = organization
      agent.name = "Conformance"
      agent.description = "Deterministic responder for the A2A TCK. No model."
      agent.skills = [ SKILL ]
      agent.harness = "none"
      agent.save!
      agent
    end

    # Installed as A2a::Inbound.handler. Returns a DirectMessage when the
    # TCK asked for one, and otherwise settles the task in place.
    def self.deliver(task)
      return unless task.recipient_agent_id && task.recipient_agent.handle == HANDLE
      return unless task.recipient_agent.owner.handle == User::SYSTEM_HANDLE
      return if task.terminal?

      message = task.messages.where(role: "ROLE_USER").order(created_at: :desc, message_id: :desc).first
      return unless message

      new(task, task.recipient_agent, message).respond
    end

    def initialize(task, agent, message)
      @task = task
      @agent = agent
      @message = message
    end

    def respond
      case prefix
      when :file_url then finish_with(file_url_part)
      when :file then finish_with(file_part)
      when :text_artifact then finish_with(text_part)
      when :data_artifact then finish_with(data_part)
      when :message then direct_message
      when :input_required then move!("TASK_STATE_INPUT_REQUIRED")
      when :reject then reject!
      when :complete then complete!(HELLO)
      else complete!(echo_text)
      end
    end

    private

    # Longer prefixes first: tck-artifact-file-url starts with tck-artifact-file.
    def prefix
      id = @message.wire_message_id.to_s
      return :file_url if id.start_with?("tck-artifact-file-url")
      return :file if id.start_with?("tck-artifact-file")
      return :text_artifact if id.start_with?("tck-artifact-text")
      return :data_artifact if id.start_with?("tck-artifact-data")
      return :message if id.start_with?("tck-message-response")
      return :input_required if id.start_with?("tck-input-required")
      return :reject if id.start_with?("tck-reject-task")
      return :complete if id.start_with?("tck-complete-task")

      :echo
    end

    def finish_with(part)
      Artifact.record!(task: @task, by: @agent, parts: [ part ])
      move!("TASK_STATE_COMPLETED")
      nil
    end

    def complete!(text)
      recorded = agent_message(text)
      move!("TASK_STATE_COMPLETED", status_message: recorded)
      nil
    end

    # The Gherkin step says "reject with error"; TaskState (§4.1.3) has
    # TASK_STATE_REJECTED, and no MUST test sends this prefix.
    def reject!
      recorded = agent_message(REJECTED_TEXT)
      move!("TASK_STATE_REJECTED", status_message: recorded)
      nil
    end

    def direct_message
      payload = {
        "messageId" => SecureRandom.uuid,
        "role" => "ROLE_AGENT",
        "contextId" => @task.context_id,
        "parts" => [ { "text" => DIRECT_TEXT } ]
      }
      # A Message answer leaves no task to track (§3.1.1).
      @task.destroy!
      DirectMessage.new(payload: payload)
    end

    def move!(state, status_message: nil)
      return if @task.state == state

      @task.transition_to!(state, by: @agent, status_message: status_message)
    end

    def agent_message(text)
      Message.record!(
        task: @task,
        role: "ROLE_AGENT",
        sender: @agent,
        parts: [ { "text" => text } ]
      )
    end

    def echo_text
      texts = Array(@message.parts).filter_map { |part| part.to_h.stringify_keys["text"].presence }
      texts.join("\n").presence || "echo"
    end

    def text_part
      { "text" => TEXT_ARTIFACT }
    end

    def file_part
      { "raw" => FILE_BYTES, "filename" => FILE_NAME, "mediaType" => FILE_TYPE }
    end

    def file_url_part
      { "url" => FILE_URL, "filename" => FILE_NAME, "mediaType" => FILE_TYPE }
    end

    def data_part
      { "data" => DATA }
    end
  end
end
