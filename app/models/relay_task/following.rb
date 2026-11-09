class RelayTask
  module Following
    FOLLOW_TURN = 45.seconds
    LEASE = 60.seconds
    POLL_INTERVAL = 5.seconds
    STALE_AFTER = 60.seconds
    RETAINED_LIMIT = 32.megabytes

    def followable?
      !task.terminal? && !auth_paused && !budget_exhausted && task.participants_admitted?
    end

    def observation_stale?(now: Time.current)
      return false if task.terminal?
      stale || observed_at.nil? || observed_at < now - STALE_AFTER
    end

    def acquire_observation!(holder:)
      with_lock do
        task.lock!
        return false unless followable?
        return false if next_follow_at && next_follow_at > Time.current
        return false if lease_expires_at && lease_expires_at > Time.current
        return false if task.relay_deliveries.where(phase: %w[reserved sending]).exists?
        update!(lease_holder: holder, lease_expires_at: LEASE.from_now, fence: fence + 1)
      end
      true
    end

    def finish_observation!(holder:, fence:, delay: POLL_INTERVAL)
      with_lock do
        return false unless owns_observation?(holder, fence)
        due = next_follow_at && next_follow_at > Time.current ? next_follow_at : Time.current + delay
        update!(lease_holder: nil, lease_expires_at: nil, next_follow_at: followable? ? due : nil)
      end
      true
    end

    def owns_observation?(holder, fence)
      lease_holder == holder && self.fence == fence && lease_expires_at && lease_expires_at > Time.current
    end

    # Caller holds the mapping lock while reserving input/cancel. This fences
    # a long observer immediately; its next socket tick sees the lost lease.
    # No network action and no release of another mutation receipt.
    def invalidate_observation!
      raise LostLease unless self.class.connection.transaction_open?
      update!(fence: fence + 1, lease_holder: nil, lease_expires_at: nil)
    end

    alias_method :invalidation_observation!, :invalidate_observation!

    def renew_observation!(holder:, fence:)
      with_lock do
        task.reload
        raise LostLease unless owns_observation?(holder, fence) && followable?
        update!(lease_expires_at: LEASE.from_now)
      end
    end

    def fail_observation!(holder:, fence:, auth: false, exhausted: false, retry_after: nil)
      with_lock do
        task.reload
        return unless owns_observation?(holder, fence) && task.participants_admitted?
        if exhausted
          task.events.create!(kind: "snapshot_boundary", settlement_evidence: false, payload: { "taskId" => task.id, "contextId" => task.context_id })
        end
        failures = follow_failures + 1
        delay = retry_after || [ 5 * 2**[ failures - 1, 4 ].min, 60 ].min
        # Bounded deterministic jitter avoids an organization-wide retry burst
        # without putting content or response text in scheduling/telemetry.
        delay += id % 3 unless retry_after
        update!(follow_failures: failures, auth_paused: auth, budget_exhausted: exhausted,
          gap: true, stale: exhausted || observation_stale?, next_follow_at: (Time.current + delay unless auth || exhausted))
      end
    end

    def check_retained_budget!
      size = task.messages.sum { |row| row.attributes.to_json.bytesize } +
        task.artifacts.sum { |row| row.attributes.to_json.bytesize } +
        task.events.sum { |row| row.attributes.slice("payload", "upstream_timestamp").to_json.bytesize } + upstream_metadata.to_json.bytesize
      raise InvalidSnapshot if size > RETAINED_LIMIT
    end

    def enqueue_follow
      return unless next_follow_at && followable?
      RelayFollowJob.set(wait_until: next_follow_at).perform_later(organization_id, task_id)
    rescue ActiveJob::EnqueueError
      # Due-time is durable; sweep recovers an enqueue loss. Exception text can
      # contain a provider body and is deliberately not logged/reported here.
      nil
    end
  end
end
