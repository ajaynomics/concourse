module A2a
  # SendMessage may return a Message without creating a Task (§3.1.1).
  DirectMessage = Struct.new(:payload, keyword_init: true) do
    def to_h
      payload
    end
  end
end
