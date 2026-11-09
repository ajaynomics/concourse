class RelaySweepJob < ApplicationJob
  queue_as :default

  # Deliberately global: enqueue-loss and crash recovery only observe/fence. This sweep
  # never calls a transport and never reclaims a SendMessage/CancelTask holder.
  def perform
    # tenancy-ok: recurring recovery visits content-free receipt IDs across tenants.
    RelayDelivery.pending.where("(phase = 'sending' AND deadline_at <= ?) OR (phase = 'reserved' AND created_at <= ?)",
      Time.current, 15.seconds.ago).find_each do |delivery| # tenancy-ok: global crash recovery fences existing receipts only
      A2a::Exchange.recover_delivery!(delivery)
    end
    # tenancy-ok: recurring due-task sweep takes the tenant from each persisted route.
    RelayTask.where("next_follow_at IS NULL OR next_follow_at <= ?", Time.current).find_each do |relay| # tenancy-ok: global observation recovery enqueues with each route's tenant
      next unless relay.followable?
      next if relay.lease_expires_at && relay.lease_expires_at > Time.current
      relay.update!(next_follow_at: Time.current) unless relay.next_follow_at
      relay.enqueue_follow
    end
  end
end
