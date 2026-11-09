module A2a
  # The operations behind JSON-RPC, the MCP caller tools, and the agent JSON
  # API. One implementation so the transports cannot drift. Every task read
  # starts at Task.visible_to (§13.1).
  class Exchange
    include NativeDelivery

    BLOCKING_LIMIT = 85
    INBOX_WAIT = 45
    POLL_INTERVAL = 0.5
    LIMITS = { blocking: :a2a_blocking_limit, inbox: :a2a_inbox_wait, poll: :a2a_poll_interval,
               heartbeat: :a2a_heartbeat_interval, stream: :a2a_stream_limit }.freeze
    DEFAULT_PAGE_SIZE = 50
    MAX_PAGE_SIZE = 100
    SUPPORTED_TEXT = %r{\Atext/}
    SUPPORTED_DATA = "application/json"
    UNSPECIFIED_CALLER_INPUT = Object.new.freeze
    class StaleReply < StandardError; end

    class << self
      def blocking_limit
        Thread.current[:a2a_blocking_limit] || BLOCKING_LIMIT
      end

      def inbox_wait
        Thread.current[:a2a_inbox_wait] || INBOX_WAIT
      end

      def poll_interval
        Thread.current[:a2a_poll_interval] || POLL_INTERVAL
      end

      def heartbeat_interval
        Thread.current[:a2a_heartbeat_interval] || Stream::HEARTBEAT
      end

      def stream_limit
        Thread.current[:a2a_stream_limit] || Stream::LIMIT
      end

      def with_limits(**limits)
        previous = LIMITS.values.index_with { |key| Thread.current[key] }
        limits.each { |name, value| Thread.current[LIMITS.fetch(name)] = value unless value.nil? }
        yield
      ensure
        previous.each { |key, value| Thread.current[key] = value }
      end
    end

    def self.send_message(caller:, recipient:, message:, configuration: {}, metadata: {}, via: nil)
      new(caller).send_message(recipient, message, configuration, metadata: metadata, via: via)
    end

    def self.send_streaming_message(caller:, recipient:, message:, configuration: {}, metadata: {}, via: nil)
      new(caller).send_streaming_message(recipient, message, configuration, metadata: metadata, via: via)
    end

    def self.subscribe(viewer:, id:, recipient:)
      new(viewer).subscribe(id, recipient: recipient)
    end

    def self.get_task(viewer:, id:, history_length: nil, recipient: nil)
      new(viewer).get_task(id, history_length:, recipient:)
    end

    def self.list_tasks(viewer:, filters: {}, recipient: nil)
      new(viewer).list_tasks(filters, recipient:)
    end

    def self.cancel_task(caller:, recipient:, id:, metadata: {})
      new(caller).cancel_task(recipient, id, metadata: metadata)
    end

    def self.reply(agent:, task_id:, parts: nil, state: nil, artifact: nil, artifacts: nil, delivery: nil, owner: nil, expected_caller_input: UNSPECIFIED_CALLER_INPUT)
      new(agent).reply(task_id, parts:, state:, artifact:, artifacts:, delivery:, owner:, expected_caller_input:)
    end

    def self.inbox(agent, state: nil, filters: {})
      new(agent).inbox(state:, filters:)
    end

    def self.next_task(agent)
      new(agent).next_task
    end

    def self.next_task_payload(agent)
      task = next_task(agent)
      { "task" => task && Serializer.task(task, artifacts: :include, caller: true) }
    end

    def self.update_card(agent, handle: nil, name: nil, description: nil, skills: nil, harness: nil, projects: nil)
      claim_card!(agent, handle: handle, name: name, description: description, skills: skills, harness: harness, projects: projects)
      Card.extended_for(agent)
    end

    def initialize(agent)
      @agent = agent
    end

    def send_message(recipient, raw_message, configuration, metadata: {}, via: nil)
      deadline = monotonic + self.class.blocking_limit
      configuration = hash(configuration)
      immediate = return_immediately?(configuration)
      history_length = optional_count(configuration, "historyLength", "history_length")
      answer, after = deliver(recipient, raw_message, configuration, metadata: metadata, via: via)
      return answer if answer.is_a?(DirectMessage)

      task = if immediate
        answer
      elsif @delivery&.execution_route == "native"
        wait_for_native_settlement(answer, deadline: deadline)
      else
        wait_for_settlement(answer, after: after)
      end
      payload = Serializer.task(task, history_length: history_length)
      if receipt = @delivery&.send_receipt(task)
        (payload["metadata"] ||= {})["concourse.send_receipt"] = receipt
      end
      payload
    end

    # SendStreamingMessage (§3.1.2) dispatches once, then observes the record.
    def send_streaming_message(recipient, raw_message, configuration, metadata: {}, via: nil)
      configuration = hash(configuration)
      return_immediately?(configuration)
      history_length = optional_count(configuration, "historyLength", "history_length")
      answer, _after = deliver(recipient, raw_message, configuration, metadata: metadata, via: via)
      return Stream.message(answer, viewer: @agent, recipient: recipient, delivery_id: @delivery&.id) if answer.is_a?(DirectMessage)

      Stream.task(answer, history_length: history_length, viewer: @agent)
    end

    # SubscribeToTask (§3.1.6): follow a task this agent can see, from where
    # it stands, until it is terminal.
    def subscribe(id, recipient:)
      task = locate(id, recipient: recipient)
      raise Error.task_terminal("read it with GetTask") if task.terminal?

      Stream.task(task, viewer: @agent)
    end

    def get_task(id, history_length: nil, recipient: nil)
      task = locate(id, recipient:)
      Serializer.task(task, history_length: history_length, recipient: sent_by_viewer?(task))
    end

    def list_tasks(filters, recipient: nil)
      filters = hash(filters)
      page_size = page_size_from(filters)
      history_length = optional_count(filters, "historyLength", "history_length")
      include_artifacts = include_artifacts?(filters)
      scope = filtered_scope(filters, recipient:)
      total = scope.count
      page, token = page_of(scope, filters, page_size)
      {
        "tasks" => page.map { |task|
          Serializer.task(
            task,
            history_length: history_length,
            artifacts: include_artifacts ? :include : :omit,
            recipient: sent_by_viewer?(task)
          )
        },
        "nextPageToken" => token,
        "pageSize" => page_size,
        "totalSize" => total
      }
    end

    def cancel_task(recipient, id, metadata: {})
      task = locate(id, recipient:)
      raise Error.new(:task_not_cancelable) unless task.caller_agent_id == @agent.id
      return cancel_native(task, metadata: metadata) unless task.inbox?
      task.cancel_by_caller!(by: @agent)
      Serializer.task(task.reload)
    rescue Task::InvalidTransition
      raise Error.new(:task_not_cancelable)
    end

    def reply(task_id, parts: nil, state: nil, artifact: nil, artifacts: nil, delivery: nil, owner: nil, expected_caller_input: UNSPECIFIED_CALLER_INPUT)
      Task.transaction do
        task = locate(task_id, recipient: @agent)
        task.lock!
        raise Error.new(:unsupported_operation) unless task.recipient_agent_id == @agent.id && task.inbox? && task.participants_admitted?
        caller_input = check_caller_input!(task, expected_caller_input) unless expected_caller_input.equal?(UNSPECIFIED_CALLER_INPUT)
        raise Error.new(:invalid_params) if !artifacts.nil? && (!Concourse.v3? || artifact)
        parts = normalize_parts(parts) if Concourse.v3? && !parts.nil?
        results = Concourse.v3? ? normalize_artifacts(artifacts || (artifact ? [ artifact ] : [])) : Array.wrap(artifact)
        if Concourse.v3? && owner.nil? && !delivery.nil?
          TaskDelivery.publish!(task: task, agent: @agent, envelope: delivery, outcome: { parts: parts, state: state, artifacts: results }) do
            record_reply(task, parts: parts, state: state, artifacts: results, caller_input: caller_input)
          end
        else
          # This keyword is internal, never accepted from an HTTP payload.
          raise Error.new(:unsupported_operation) if owner && (owner != Current.user || @agent.owner_id != owner.id)
          # Ordinary mailbox replies report recipient outcomes, not transport state.
          raise Error.new(:unsupported_operation) if Concourse.v3? && owner.nil? && state.in?(%w[TASK_STATE_CANCELED TASK_STATE_SUBMITTED])
          record_reply(task, parts: parts, state: state, artifacts: results, caller_input: owner.nil? ? caller_input : nil)
        end
        task.reload
      end
    rescue Task::Terminal
      raise Error.task_terminal
    rescue Task::InvalidTransition, Task::NotRecipient
      raise Error.new(:unsupported_operation)
    end

    def inbox(state: nil, filters: {})
      scope = Task.visible_to(@agent).inbox.where(recipient_agent: @agent).includes(caller_agent: :owner)
      scope = scope.where(state: state) if state.present?
      unless Concourse.v3?
        return scope.order(updated_at: :desc, id: :desc).map { |task| Serializer.task(task, artifacts: :include, caller: true) }
      end
      filters = hash(filters)
      raise Error.new(:invalid_params) unless (filters.keys - %w[pageSize pageToken]).empty?
      page_size = page_size_from(filters)
      # The mailbox client deduplicates genuine caller message IDs locally;
      # experimental claims do not hide unfinished correspondence.
      scope = scope.unfinished.where(<<~SQL.squish).order(created_at: :desc, id: :desc)
        EXISTS (SELECT 1 FROM messages WHERE messages.task_id = tasks.id
          AND messages.role = 'ROLE_USER' AND messages.sender_agent_id = tasks.caller_agent_id)
      SQL
      page, token = page_of(scope, filters, page_size, time_column: :created_at)
      Serializer.mailbox_page(page, next_page_token: token, page_size: page_size) do |task|
        encode_page_token(task, time_column: :created_at)
      end
    end

    # Oldest actionable inbox task. Actionable means SUBMITTED, or
    # INPUT_REQUIRED with a caller message newer than the status that asked
    # for input. WORKING and an unanswered INPUT_REQUIRED are the recipient's
    # to finish, not to pick up again.
    def next_task
      task = oldest_actionable
      return task if task
      return if self.class.inbox_wait <= 0
      unless Waiters.acquire(@agent.organization_id)
        log_waiter_cap("next_task")
        return
      end

      begin
        deadline = monotonic + self.class.inbox_wait
        loop do
          # Removed from the organization mid-wait: nothing more of it.
          return unless @agent.admitted?

          task = oldest_actionable
          return task if task

          remaining = deadline - monotonic
          return if remaining <= 0

          Waiters.idle([ self.class.poll_interval, remaining ].min)
        end
      ensure
        Waiters.release(@agent.organization_id)
      end
    end

    # Projects replace the agent's list when given; joining one means naming
    # every project the agent is in. Only existing projects can be named.
    def self.claim_card!(agent, handle: nil, name: nil, description: nil, skills: nil, harness: nil, projects: nil)
      agent.transaction { write_card!(agent, handle:, name:, description:, skills:, harness:, projects:) }
      agent
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      raise Error.new(:invalid_params)
    end

    def self.write_card!(agent, handle:, name:, description:, skills:, harness:, projects:)
      if handle.present?
        normalized = handle.to_s.downcase
        raise Error.new(:invalid_params) unless normalized.match?(User::HANDLE_FORMAT)
        raise Error.new(:invalid_params) if agent.handle.present? && agent.handle != normalized

        agent.handle = normalized
      elsif agent.handle.blank?
        raise Error.new(:invalid_params)
      end

      agent.name = name if name
      agent.description = description if description
      agent.harness = harness if harness
      agent.skills = normalize_skills(skills) unless skills.nil?
      agent.save!
      agent.projects = projects_named(agent.organization, projects) unless projects.nil?
    end

    def self.projects_named(organization, slugs)
      raise Error.new(:invalid_params) unless slugs.is_a?(Array) && slugs.all?(String)

      slugs = slugs.uniq
      found = organization.projects.where(slug: slugs).to_a
      raise Error.new(:invalid_params) unless found.size == slugs.size

      found
    end
    private_class_method :write_card!, :projects_named

    def self.normalize_skills(skills)
      raise Error.new(:invalid_params) unless skills.is_a?(Array)

      skills.map do |skill|
        hash = skill.to_h.stringify_keys
        tags = Array(hash["tags"]).map(&:to_s).reject(&:blank?)
        raise Error.new(:invalid_params) if hash["id"].blank? || hash["name"].blank? || hash["description"].blank? || tags.empty?

        {
          "id" => hash["id"].to_s,
          "name" => hash["name"].to_s,
          "description" => hash["description"].to_s,
          "tags" => tags,
          "examples" => Array(hash["examples"]).map(&:to_s),
          "inputModes" => Array(hash["inputModes"] || hash["input_modes"]).map(&:to_s),
          "outputModes" => Array(hash["outputModes"] || hash["output_modes"]).map(&:to_s)
        }
      end
    end

    # The directory is one organization's, optionally one of its projects.
    # An unknown project is an error, not an empty list, so a typo shows.
    def self.find_agents(organization, query: nil, project: nil, limit: Agent::DIRECTORY_PAGE)
      agents = organization.agents.listed
      if project.present?
        found = organization.projects.find_by(slug: project.to_s)
        raise Error.new(:invalid_params) unless found

        agents = agents.in_project(found)
      end
      agents.search(query, limit: limit)
    end

    private

    def check_caller_input!(task, expected)
      unless Concourse.v3? && expected.is_a?(Hash) && expected.size == 2 && expected.key?("cursor") && expected.key?("messageId") &&
          expected["cursor"].is_a?(String) && expected["cursor"].match?(/\A[1-9][0-9]*\z/) &&
          expected["messageId"].is_a?(String) && expected["messageId"].present?
        raise Error.new(:invalid_params)
      end
      actual = task.latest_caller_input
      raise StaleReply unless expected == actual
      actual.deep_dup
    end

    def record_reply(task, parts:, state:, artifacts:, caller_input: nil)
      raise Error.task_terminal if task.terminal?
      status_message = Message.record!(task: task, role: "ROLE_AGENT", sender: @agent, parts: parts) if parts.present?
      recorded = artifacts.map { |artifact| Artifact.record!(task: task, by: @agent, **artifact) }
      output = if caller_input
        { "version" => 1, "callerInput" => caller_input,
          "messageIds" => Array(status_message).map(&:wire_message_id), "artifactIds" => recorded.map(&:artifact_id) }
      end
      # A2A §4.1.1/§4.1.4: bind these exact outputs, not a later Task snapshot or retained status text.
      task.with_reply_output(output) do
        if Concourse.v3? && task.state == state && (state == "TASK_STATE_WORKING" || (state == "TASK_STATE_INPUT_REQUIRED" && status_message))
          # A2A §3.2.2: a new question is correspondence, not an artificial state transition.
          task.restate!(by: @agent, status_message: status_message)
        elsif state.present?
          task.transition_to!(state, by: @agent, status_message: status_message)
        elsif status_message || artifacts.any?
          task.restate!(by: @agent, status_message: status_message)
        end
      end
    end

    def normalize_artifacts(values)
      raise Error.new(:invalid_params) unless values.is_a?(Array) && values.size <= 20
      values.map do |value|
        item = hash(value)
        raise Error.new(:invalid_params) unless (item.keys - %w[parts name description metadata extensions]).empty?
        raise Error.new(:invalid_params) unless item["parts"].is_a?(Array) && item["parts"].size.between?(1, 100)
        item["parts"] = normalize_parts(item["parts"])
        %w[name description].each do |key|
          raise Error.new(:invalid_params) if item.key?(key) && !item[key].nil? && !item[key].is_a?(String)
        end
        raise Error.new(:invalid_params) if item.key?("metadata") && !item["metadata"].is_a?(Hash)
        raise Error.new(:invalid_params) if item.key?("extensions") && (!item["extensions"].is_a?(Array) || !item["extensions"].all?(String))
        item.symbolize_keys
      end
    end

    # A messageId the agent used in an organization it has since left names
    # a task it can no longer see, so it is refused like any other mismatch.
    def idempotent_task(existing, recipient)
      task = Task.visible_to(@agent).find_by(id: existing.task_id)
      raise Error.new(:invalid_params) unless task && task.participants_admitted?
      unless task.caller_agent_id == @agent.id && task.recipient_agent_id == recipient.id && task.organization_id == @agent.organization_id
        raise Error.new(:invalid_params)
      end

      task
    end

    def continue(recipient, task_id, context_id)
      # Visibility comes first (§13.1). A v3 inbox recipient using SendMessage
      # backwards needs a definite pre-write refusal, not TaskNotFound uncertainty.
      task = locate(task_id, recipient: Concourse.v3? ? nil : recipient)
      if Concourse.v3? && task.inbox? && task.recipient_agent_id == @agent.id && task.caller_agent_id != @agent.id
        raise Error.reply_required
      end
      raise Error.new(:task_not_found) unless task.recipient_agent_id == recipient.id
      raise Error.new(:unsupported_operation) unless task.caller_agent_id == @agent.id
      raise Error.task_terminal("send a new message without a task ID to start a new task") if task.terminal?
      if context_id && context_id != task.context_id
        raise Error.new(:invalid_params)
      end

      task
    end

    def locate(id, recipient: nil)
      raise Error.new(:invalid_params) if id.blank?

      scope = Task.visible_to(@agent)
      scope = scope.where(recipient_agent: recipient) if recipient
      task = scope.find_by(id: id)
      raise Error.new(:task_not_found) unless task && task.participants_admitted?
      task
    end

    # The caller's view of its own task names the agent it went to, as the
    # recipient's inbox names the caller.
    def sent_by_viewer?(task)
      task.caller_agent_id == @agent.id
    end

    def filtered_scope(filters, recipient:)
      scope = Task.visible_to(@agent)
      scope = scope.where(recipient_agent: recipient) if recipient
      context_id = field(filters, "contextId", "context_id").presence
      scope = scope.where(context_id: context_id) if context_id
      status = field(filters, "status").presence
      if status
        raise Error.new(:invalid_params) unless Task::STATES.include?(status) || status == "TASK_STATE_UNSPECIFIED"

        scope = scope.where(state: status)
      end
      after = field(filters, "statusTimestampAfter", "status_timestamp_after").presence
      scope = scope.where(status_at: parse_time(after)..) if after
      scope.order(status_at: :desc, id: :desc)
    end

    def page_of(scope, filters, page_size, time_column: :status_at)
      raise Error.new(:invalid_params) unless time_column.in?(%i[status_at created_at])
      cursor = field(filters, "pageToken", "page_token").presence
      relation = scope
      if cursor
        time, id = decode_page_token(cursor)
        relation = if time_column == :created_at
          relation.where("created_at < :time OR (created_at = :time AND id < :id)", time: time, id: id)
        else
          relation.where("status_at < :time OR (status_at = :time AND id < :id)", time: time, id: id)
        end
      end
      rows = relation.limit(page_size + 1).to_a
      page = rows.first(page_size)
      token = rows.size > page_size ? encode_page_token(page.last, time_column: time_column) : ""
      [ page, token ]
    end

    def encode_page_token(task, time_column: :status_at)
      Base64.urlsafe_encode64("#{task.public_send(time_column).utc.iso8601(6)}|#{task.id}", padding: false)
    end

    def decode_page_token(token)
      raise Error.new(:invalid_params) unless token.is_a?(String) && token.bytesize <= 1024
      raw = Base64.urlsafe_decode64(token)
      time_s, id = raw.split("|", 2)
      time = Time.iso8601(time_s)
      raise Error.new(:invalid_params) if id.blank?

      [ time, id ]
    rescue ArgumentError
      raise Error.new(:invalid_params)
    end

    def page_size_from(filters)
      return DEFAULT_PAGE_SIZE unless filters.key?("pageSize") || filters.key?("page_size")

      value = field(filters, "pageSize", "page_size")
      raise Error.new(:invalid_params) unless value.is_a?(Integer) && value.between?(1, MAX_PAGE_SIZE)

      value
    end

    def include_artifacts?(filters)
      return false unless filters.key?("includeArtifacts") || filters.key?("include_artifacts")

      value = field(filters, "includeArtifacts", "include_artifacts")
      raise Error.new(:invalid_params) unless value == true || value == false

      value
    end

    def oldest_actionable
      if Concourse.v3?
        return Task.visible_to(@agent).inbox.unfinished.where(recipient_agent: @agent)
          .where(Task::V3_RECIPIENT_WAITING).order(:created_at, :id).first
      end
      newer_user_message = <<~SQL.squish
        EXISTS (
          SELECT 1 FROM messages
          WHERE messages.task_id = tasks.id
            AND messages.role = 'ROLE_USER'
            AND messages.created_at > tasks.status_at
        )
      SQL
      actionable_since = <<~SQL.squish
        CASE
          WHEN tasks.state = 'TASK_STATE_SUBMITTED' THEN tasks.status_at
          ELSE (
            SELECT MIN(messages.created_at) FROM messages
            WHERE messages.task_id = tasks.id
              AND messages.role = 'ROLE_USER'
              AND messages.created_at > tasks.status_at
          )
        END
      SQL
      Task.visible_to(@agent).inbox
        .where(recipient_agent: @agent)
        .where(
          "tasks.state = ? OR (tasks.state = ? AND #{newer_user_message})",
          "TASK_STATE_SUBMITTED",
          "TASK_STATE_INPUT_REQUIRED"
        )
        .order(Arel.sql("#{actionable_since}, tasks.id"))
        .first
    end

    # Blocking SendMessage (§3.2.2) succeeds only after settlement. A platform
    # limit leaves the work intact and returns its ID for GetTask/SubscribeToTask.
    def wait_for_settlement(task, after:)
      current = locate(task.id)
      return current if settled_after?(current, after)
      unless Waiters.acquire(@agent.organization_id)
        log_waiter_cap("send_message")
        raise RelayError.new("RELAY_WAIT_LIMIT", task_id: current.id)
      end

      begin
        deadline = monotonic + self.class.blocking_limit
        loop do
          current = locate(task.id)
          return current if settled_after?(current, after)

          remaining = deadline - monotonic
          if remaining <= 0
            log_blocking_cap(current)
            raise RelayError.new("RELAY_WAIT_LIMIT", task_id: current.id)
          end

          Waiters.idle([ self.class.poll_interval, remaining ].min)
        end
      ensure
        Waiters.release(@agent.organization_id)
      end
    end

    def settled_after?(task, after)
      return false unless task.terminal? || task.interrupted?
      return true if after.nil?

      task.status_at > after
    end

    def log_blocking_cap(task)
      Rails.event.notify(
        "concourse.a2a.blocking_cap",
        task_id: task.id,
        limit_seconds: self.class.blocking_limit
      )
    end

    def log_waiter_cap(kind)
      Rails.event.notify("concourse.a2a.waiter_cap", kind: kind, limit: Waiters.limit)
    end

    def reject_push_config!(configuration)
      return unless configuration.key?("taskPushNotificationConfig") || configuration.key?("task_push_notification_config")

      raise Error.new(:push_notification_not_supported)
    end

    def return_immediately?(configuration)
      return false unless configuration.key?("returnImmediately") || configuration.key?("return_immediately")

      value = field(configuration, "returnImmediately", "return_immediately")
      raise Error.new(:invalid_params) unless value == true || value == false

      value
    end

    def optional_count(hash, camel, snake)
      return nil unless hash.key?(camel) || hash.key?(snake)

      value = field(hash, camel, snake)
      raise Error.new(:invalid_params) unless value.is_a?(Integer) && value >= 0

      value
    end

    def normalize_parts(parts)
      raise Error.new(:invalid_params) unless parts.is_a?(Array) && parts.any?

      parts.map { |part| normalize_part(part) }
    end

    def normalize_part(part)
      hash = hash(part)
      text = hash["text"]
      data = hash["data"]
      kinds = %w[text data raw url].select { |key| hash.key?(key) }
      raise Error.new(:invalid_params) unless kinds.size == 1 && !hash[kinds.first].nil?
      raise Error.new(:content_type_not_supported) if hash.key?("raw") || hash.key?("url")

      media = field(hash, "mediaType", "media_type")
      raise Error.new(:invalid_params) if media && (!media.is_a?(String) || media.blank?)
      if !text.nil?
        raise Error.new(:invalid_params) unless text.is_a?(String)
        raise Error.new(:content_type_not_supported) if media && !media.match?(SUPPORTED_TEXT)

        part_attributes(hash).merge("text" => text).tap { |out| out["mediaType"] = media if media }
      else
        raise Error.new(:content_type_not_supported) if media && media != SUPPORTED_DATA

        part_attributes(hash).merge("data" => data).tap { |out| out["mediaType"] = media if media }
      end
    end

    def part_attributes(part)
      raise Error.new(:invalid_params) if part.key?("metadata") && !part["metadata"].is_a?(Hash)
      raise Error.new(:invalid_params) if part.key?("filename") && !part["filename"].is_a?(String)

      part.slice("metadata", "filename")
    end

    def required_string(hash, camel, snake = nil)
      value = field(hash, camel, snake)
      raise Error.new(:invalid_params) unless value.is_a?(String) && value.present?

      value
    end

    # Client concourse.* keys cannot supply authenticated gateway attribution.
    # Owner attribution enters through Exchange's trusted keyword, before send.
    def metadata_of(message)
      metadata = field(message, "metadata")
      return {} if metadata.nil?
      raise Error.new(:invalid_params) unless metadata.is_a?(Hash)

      metadata.reject { |key, _value| key.to_s.start_with?("concourse.") }
    end

    def string_list(hash, camel, snake = nil)
      return [] unless hash.key?(camel) || (snake && hash.key?(snake))

      value = field(hash, camel, snake)
      raise Error.new(:invalid_params) unless value.is_a?(Array) && value.all?(String)

      value
    end

    def parse_time(value)
      raise Error.new(:invalid_params) unless value.is_a?(String)

      Time.iso8601(value)
    rescue ArgumentError
      raise Error.new(:invalid_params)
    end

    def hash(value)
      raise Error.new(:invalid_params) unless value.is_a?(Hash)

      value.stringify_keys
    end

    def field(hash, camel, snake = nil)
      return hash[camel] if hash.key?(camel)
      return hash[snake] if snake && hash.key?(snake)

      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
