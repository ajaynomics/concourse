class RelayFollowJob < ApplicationJob
  queue_as :relay_follow

  # Observation only (§3.1.3/§3.1.6); never SendMessage or CancelTask. The
  # persisted capability, not a later card edit, chooses Subscribe versus Get.
  def perform(organization_id, task_id)
    organization = Organization.find_by(id: organization_id) # tenancy-ok: job's explicit tenant root
    task = organization&.tasks&.find_by(id: task_id)
    relay = task&.relay_task
    return unless relay && relay.followable?
    unless egress_enabled?
      relay.with_lock do
        relay.update!(stale: true, gap: true, next_follow_at: nil) unless relay.lease_expires_at && relay.lease_expires_at > Time.current
      end
      return
    end
    holder = SecureRandom.uuid
    slot = RelayNetworkSlot.acquire(kind: :follow, organization: organization, holder: holder)
    return unless slot
    begin
      return unless relay.acquire_observation!(holder: holder)
      fence = relay.fence
      deadline = monotonic + RelayTask::Following::FOLLOW_TURN
      ActiveRecord::Base.connection_pool.release_connection
      token = Ajent::RelayToken.fetch(resource: relay.resource)
      admission = -> { check_admission!(relay, slot, holder, fence) }
      admission.call
      rpc_id = SecureRandom.uuid
      params = { "id" => relay.native_task_id }
      params["tenant"] = relay.tenant if relay.tenant.present?
      body = { "jsonrpc" => "2.0", "id" => rpc_id, "method" => relay.native_streaming? ? "SubscribeToTask" : "GetTask", "params" => params }.to_json
      provider = A2a::NativeTransport.new(organization_id: organization.id, recipient_id: relay.recipient_agent_id, purpose: :follow,
        attribution: { organization: organization.slug, recipient: relay.recipient_agent.qualified_handle })
      arguments = { url: relay.endpoint_url, resource: relay.resource, body: body, token: token,
        headers: { "Concourse-Caller" => relay.caller_agent.qualified_handle, "Concourse-Task" => task.id }, admission: admission }
      ActiveRecord::Base.connection_pool.release_connection
      if relay.native_streaming?
        first = true
        renew_at = monotonic + 10
        tick = -> do
          admission.call
          if monotonic >= renew_at
            renew_follow!(relay, slot, holder, fence)
            renew_at = monotonic + 10
          end
        end
        response = provider.subscribe(**arguments, on_tick: tick, deadline: deadline) do |envelope|
          unless envelope.is_a?(Hash) && envelope["jsonrpc"] == "2.0" && envelope["id"] == rpc_id &&
              (envelope.key?("result") ^ envelope.key?("error"))
            raise A2a::NativeResult::Invalid
          end
          if envelope.key?("error")
            A2a::NativeResult.parse(envelope.to_json, rpc_id: rpc_id)
            raise A2a::NativeTransport::Unconfirmed.new(:native_error, phase: :http)
          end
          payload = envelope["result"]
          raise A2a::NativeResult::Invalid if first && !(payload.is_a?(Hash) && payload.key?("task"))
          raise A2a::NativeResult::Invalid if !first && payload.is_a?(Hash) && payload.key?("task")
          observe!(relay, payload, slot, holder, fence)
          first = false
          !task.reload.terminal?
        ensure
          ActiveRecord::Base.connection_pool.release_connection
        end
        raise A2a::NativeTransport::Unconfirmed.new(:missing_snapshot, phase: :http) if response.status == 200 && first
      else
        response = provider.post(**arguments)
        if response.status == 200
          result = A2a::NativeResult.parse_task(response.body, rpc_id: rpc_id)
          if result.error
            raise A2a::NativeTransport::Unconfirmed.new(:native_error, phase: :http)
          end
          observe!(relay, { "task" => result.task }, slot, holder, fence)
        end
      end
      if response.status != 200
        relay.fail_observation!(holder: holder, fence: fence, auth: [ 401, 403 ].include?(response.status),
          retry_after: retry_delay(response.headers["retry-after"]))
      end
    rescue Ajent::RelayToken::Rejected
      relay.fail_observation!(holder: holder, fence: fence, auth: true) if fence
    rescue A2a::NativeResult::Invalid, RelayTask::InvalidSnapshot
      relay.fail_observation!(holder: holder, fence: fence, exhausted: true) if fence
    rescue A2a::NativeTransport::Error => error
      exhausted = %i[reply_limit event_limit].include?(error.reason)
      relay.fail_observation!(holder: holder, fence: fence, exhausted: exhausted) if fence
    rescue Ajent::RelayToken::Error
      relay.fail_observation!(holder: holder, fence: fence) if fence
    rescue RelayTask::LostLease, Agent::Unadmitted, ActiveRecord::RecordNotFound
      # Removal/expiry/mutation interruption cannot resurrect output or release
      # a successor's lease. A due sweep recovers unfinished observation work.
      nil
    ensure
      current = organization.relay_tasks.find_by(task_id: task_id)
      finished = current&.finish_observation!(holder: holder, fence: fence) if fence
      slot.release(holder)
      ActiveRecord::Base.connection_pool.release_connection
      current&.enqueue_follow if finished && egress_enabled?
    end
  end

  private

  def observe!(relay, payload, slot, holder, fence)
    relay.with_lock do
      check_admission!(relay, slot, holder, fence, release: false)
      relay.observe_native_event!(payload: payload, holder: holder, fence: fence)
    end
  ensure
    ActiveRecord::Base.connection_pool.release_connection
  end

  def check_admission!(relay, slot, holder, fence, release: true)
    relay.reload
    relay.task.reload
    slot.reload
    raise RelayTask::LostLease unless relay.owns_observation?(holder, fence) && slot.held_by?(holder) && egress_enabled?
    raise Agent::Unadmitted unless relay.task.participants_admitted?
    true
  ensure
    ActiveRecord::Base.connection_pool.release_connection if release
  end

  def renew_follow!(relay, slot, holder, fence)
    relay.with_lock do
      check_admission!(relay, slot, holder, fence, release: false)
      changed = RelayNetworkSlot.where(id: slot.id, holder: holder).where("expires_at > ?", Time.current) # tenancy-ok: acquired content-free slot bound to scoped job/holder.
        .update_all(expires_at: RelayNetworkSlot::MAX_LEASE.fetch("follow").from_now)
      raise RelayTask::LostLease unless changed == 1
      relay.renew_observation!(holder: holder, fence: fence)
    end
  ensure
    ActiveRecord::Base.connection_pool.release_connection
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def egress_enabled?
    Agent.native_relay_complete? && Rails.app.creds.option(:relay, :outbound_enabled).to_s == "true"
  end

  def retry_delay(value)
    return unless value.is_a?(String)
    seconds = if value.match?(/\A\d+\z/)
      value.to_i
    else
      Time.httpdate(value) - Time.current
    end
    [ [ seconds, 0 ].max, 300 ].min
  rescue ArgumentError
    nil
  end
end
