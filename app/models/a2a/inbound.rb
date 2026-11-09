module A2a
  # Extension point for a deterministic responder (the conformance agent).
  # SendMessage calls this after the task is recorded and before a blocking
  # wait, so a handler can settle the task in-process. A handler may return
  # A2a::Conformance::DirectMessage to answer with a Message instead of a
  # Task (§3.1.1); any other return value is ignored.
  module Inbound
    class << self
      attr_accessor :handler
    end

    def self.deliver(task)
      return Network.deliver(task) if Concourse.v3? && Network.agent?(task.recipient_agent)

      handler&.call(task)
    end
  end
end
