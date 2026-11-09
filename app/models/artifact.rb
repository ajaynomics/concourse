class Artifact < ApplicationRecord
  self.primary_key = "artifact_id"
  self.implicit_order_column = "created_at"

  belongs_to :task, touch: true

  validates :parts, presence: true
  validate :parts_are_a_list

  before_validation :assign_artifact_id, on: :create
  after_create -> { task.events.create!(artifact: self, created_at: created_at) }, if: -> { task.inbox? }
  after_create -> { AgentEvent.artifact_created!(self) }
  after_save -> { task.mark_content_changed! }

  # Only the recipient attaches a result, and not after the task is final.
  def self.record!(task:, by:, parts:, name: nil, description: nil, metadata: {}, extensions: [])
    task.ensure_inbox!
    raise Task::NotRecipient unless by&.id == task.recipient_agent_id
    raise Task::Terminal if task.terminal?

    create!(task: task, name: name, description: description, parts: parts, metadata: metadata, extensions: extensions)
  end

  private

  def assign_artifact_id
    self.artifact_id ||= SecureRandom.uuid
  end

  def parts_are_a_list
    errors.add(:parts, "must be a list") unless parts.is_a?(Array)
  end
end
