module InboxDoorbell
  # Hints only: subscribers always re-read their scoped mailbox. Duplicate or
  # lost hints cannot acknowledge work, change its route, or expose content.
  def ring_doorbell(reason)
    return unless inbox?
    agent = reason == "inbox" ? recipient_agent : caller_agent
    return unless Task.visible_to(agent).inbox.exists?(id)

    ActionCable.server.broadcast("agent_doorbell:#{agent.id}", { reason: reason, taskId: id })
  rescue StandardError
    # The mailbox already committed. A cable outage must not make a caller
    # resend committed work; the client's backstop will discover it.
    Rails.event.notify("concourse.doorbell.unavailable")
  end
end
