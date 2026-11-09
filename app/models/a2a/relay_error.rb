module A2a
  # A relay failure is not an authentication challenge for the gateway caller.
  # ErrorInfo is the A2A §5.4 extensible error-details envelope; only public,
  # scoped IDs may be passed here, never upstream bodies or native identifiers.
  class RelayError < Error
    def initialize(reason, task_id: nil, delivery_id: nil)
      super(:internal)
      @data = [ {
        "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
        "reason" => reason,
        "domain" => "concourse.example.com",
        "metadata" => { "taskId" => task_id, "deliveryId" => delivery_id }.compact
      } ]
    end
  end
end
