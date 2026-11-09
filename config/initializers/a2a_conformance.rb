# The conformance agent answers in-process. Its row is a seed (db/seeds.rb),
# which the web container runs after migrating on every boot.
Rails.application.config.after_initialize do
  A2a::Inbound.handler = A2a::Conformance.method(:deliver)
end
