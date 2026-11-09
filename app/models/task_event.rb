# A status/artifact change in causal order (§3.5.2), or an internal v3 caller
# input observation. Streams skip internal input facts while advancing their
# cursor; these facts cannot invent TaskStatus or executor state.
class TaskEvent < ApplicationRecord
  belongs_to :task
  belongs_to :status_message, class_name: "Message", primary_key: :message_id, optional: true
  belongs_to :artifact, optional: true

  # Observed wire deltas never dereference a subsequently replaced artifact.
  # Retention may delete events, but an observed event cannot be rewritten.
  before_update -> { throw :abort }, if: -> { kind_in_database.present? }
  after_create_commit :ring_inbox_doorbell

  # A status event is a TaskStatus as it was: Serializer.status reads it
  # as it reads a task.
  alias_attribute :status_at, :created_at

  def artifact?
    artifact_id.present? || kind == "artifact"
  end

  # This internal event kind is written only after the optional recipient fence succeeds.
  # It is not an assertion of model execution, and ordinary/unfenced replies remain unbound.
  def reply_output(task: self.task)
    return unless Concourse.v3? && task.inbox? && kind == "reply" && state.present?
    output = payload.is_a?(Hash) && payload["concourse.output"]
    return unless output.is_a?(Hash) && output["version"] == 1
    input = output["callerInput"]
    return unless input.is_a?(Hash) && input.keys.sort == %w[cursor messageId] &&
      input["cursor"].is_a?(String) && input["cursor"].match?(/\A[1-9][0-9]*\z/) &&
      input["messageId"].is_a?(String) && input["messageId"].present?
    return unless %w[messageIds artifactIds].all? { |key| output[key].is_a?(Array) &&
      output[key].all? { |id| id.is_a?(String) && id.present? } && output[key].uniq == output[key] }

    output
  end

  def reply_metadata(task: self.task)
    output = reply_output(task: task)
    { "version" => 1, "callerInput" => output["callerInput"].deep_dup, "statusEventId" => id.to_s } if output
  end

  # One task-scoped ledger read per snapshot, not one lookup for every history/artifact item.
  def self.reply_bindings(task)
    bindings = { "messages" => {}, "artifacts" => {} }
    return bindings unless Concourse.v3? && task.inbox?

    task.events.where(kind: "reply").find_each do |event|
      output = event.reply_output(task: task)
      next unless output
      metadata = event.reply_metadata(task: task)
      { "messageIds" => "messages", "artifactIds" => "artifacts" }.each do |field, category|
        output[field].each do |id|
          index = bindings.fetch(category)
          # Corrupt/ambiguous membership never selects a winner by history order.
          index[id] = index.key?(id) ? nil : metadata
        end
      end
    end
    bindings
  end

  private

  def ring_inbox_doorbell
    return unless task.inbox? && !artifact? && state.present?
    # The status ledger survives Exchange#reply's reload before commit, unlike
    # Task's saved_changes. A separate instance avoids changing the caller's
    # association caches; a direct Message result may already have retired it.
    committed_task = task.organization.tasks.find_by(id: task_id)
    return unless committed_task&.inbox?
    committed_task.ring_doorbell("inbox") if committed_task.actionable?
    committed_task.ring_doorbell("reply") if committed_task.events.where(id: ...id).exists?
  end
end
