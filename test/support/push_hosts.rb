# PushConfig resolves webhook hosts; tests answer from a fixed table instead of DNS.
module PushHosts
  HOOK = "https://hooks.example.com/concourse"
  ADDRESSES = { "hooks.example.com" => [ "93.184.215.14" ], "internal.example.com" => [ "10.0.0.5" ],
                "loopback.example.com" => [ "93.184.215.14", "127.0.0.1" ] }.freeze

  def stub_push_hosts
    @original_addresses = PushConfig.method(:addresses)
    PushConfig.define_singleton_method(:addresses) { |host| ADDRESSES.fetch(host) { raise SocketError, host } }
  end

  def restore_push_hosts
    PushConfig.define_singleton_method(:addresses, @original_addresses)
  end
end
