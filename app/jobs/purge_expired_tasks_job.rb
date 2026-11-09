# Retention is the same thirty days everywhere, so this sweep is
# deliberately global: it walks every organization's tasks.
class PurgeExpiredTasksJob < ApplicationJob
  RETENTION = 30.days

  def perform
    # Inbox updated_at remains its legacy content clock. Native observation and
    # lease writes must not keep native/held content alive indefinitely.
    scope = Task.where(execution_route: "inbox", updated_at: ...RETENTION.ago) # tenancy-ok: retention applies to every organization
      .or(Task.where(execution_route: %w[native held], content_changed_at: ...RETENTION.ago)) # tenancy-ok: retention applies to every organization
    count = scope.count
    scope.find_each do |task|
      # Use the send's recipient lock and commit fences with deletion. A crash
      # must leave either the legacy messages or their tombstones, never neither.
      task.recipient_agent.with_lock do
        task.messages.where(role: "ROLE_USER").where.not(client_message_id: nil).find_each do |message|
          RelayDelivery.expire_legacy_message!(message)
        end
        task.destroy!
      end
    end
    RelayDelivery.where(expired_at: nil, content_changed_at: ...RETENTION.ago).find_each(&:expire!) # tenancy-ok: global content retention, not dispatch
    RelayContext.where(content_changed_at: ...RETENTION.ago).find_each do |context| # tenancy-ok: global mapping retention
      # A fresh retained exchange still needs its scoped native context binding.
      active = context.organization.tasks.where(caller_agent_id: context.caller_agent_id,
        recipient_agent_id: context.recipient_agent_id, context_id: context.public_context_id).exists?
      context.destroy! unless active
    end
    Rails.event.notify("concourse.retention.purged", count: count)
  end
end
