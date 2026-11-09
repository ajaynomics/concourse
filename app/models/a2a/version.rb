module A2a
  # §3.6. An empty A2A-Version is 0.3, not "whatever we speak". Patch numbers
  # are ignored. This server speaks 1.0 only, so 0.3 is VersionNotSupported.
  module Version
    SUPPORTED = "1.0"

    def self.supported?(value)
      major_minor(value) == SUPPORTED
    end

    def self.major_minor(value)
      raw = value.to_s.strip
      return "0.3" if raw.empty?

      parts = raw.split(".")
      return unless parts.size >= 2
      return unless parts[0].match?(/\A\d+\z/) && parts[1].match?(/\A\d+\z/)

      "#{parts[0]}.#{parts[1]}"
    end
  end
end
