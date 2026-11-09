# Keys for encrypted columns (PushConfig#token), derived from secret_key_base
# so no separate secret has to be provisioned. Values set through
# ACTIVE_RECORD_ENCRYPTION__* or credentials still win. Rotating
# secret_key_base makes stored tokens unreadable; agents then PUT again.
Rails.application.configure do
  encryption = config.active_record.encryption
  %i[primary_key deterministic_key key_derivation_salt].each do |name|
    next if Rails.app.creds.option(:active_record_encryption, name).present?

    encryption[name] = key_generator.generate_key("active_record_encryption.#{name}", 32).unpack1("H*")
  end
end
