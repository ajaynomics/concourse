require "test_helper"

# `.env.example` is where a new developer, and the next deploy, learns what
# the app reads. A setting read through Rails.app.creds but missing there is
# discoverable only by a failed boot, so the file is checked against the code
# that reads it rather than trusted.
class EnvExampleTest < ActiveSupport::TestCase
  READ = /creds\.(?:option|require)\(\s*:(\w+)\s*,\s*:(\w+)/
  PLAIN = /ENV(?:\["|\.fetch\("|\.key\?\(")([A-Z][A-Z0-9_]*)"/

  # Set by the machinery around the app, never by whoever runs it: Kamal stamps
  # the revision, the image build boots with a dummy key, CI says it is CI,
  # and boot.rb points Bundler at the Gemfile.
  PROVIDED = %w[ KAMAL_VERSION REVISION SECRET_KEY_BASE_DUMMY CI BUNDLE_GEMFILE ].to_set

  test ".env.example lists every setting the app reads through creds" do
    missing = settings_read - settings_listed

    assert_empty missing, "read by the app but absent from .env.example: #{missing.to_a.sort.join(', ')}"
  end

  test ".env.example lists nothing the app does not read" do
    stale = settings_listed - settings_read

    assert_empty stale, "listed in .env.example but read nowhere: #{stale.to_a.sort.join(', ')}"
  end

  # A plain ENV read is a process knob rather than a setting (S3 governs
  # settings), but it is still something an operator can turn, so it is
  # documented, commented out, beside the settings.
  test ".env.example documents every knob read straight from ENV" do
    undocumented = plain_reads - PROVIDED - settings_read - documented

    assert_empty undocumented, "read from ENV but not documented in .env.example: #{undocumented.to_a.sort.join(', ')}"
    assert_includes plain_reads, "JOB_CONCURRENCY", "the scan has stopped seeing plain reads"
  end

  test "the scan finds the settings it is meant to guard" do
    assert_operator settings_read.size, :>=, 10
    assert_includes settings_read, "OIDC__CLIENT_SECRET"
  end

  private
    # creds.option(:oidc, :client_id) is read from ENV as OIDC__CLIENT_ID.
    def settings_read
      Dir[Rails.root.join("{config,app,lib}/**/*.{yml,rb,erb}")].flat_map do |path|
        File.read(path).scan(READ).map { |service, key| "#{service}__#{key}".upcase }
      end.to_set
    end

    def plain_reads
      sources = Dir[Rails.root.join("{config,app,lib}/**/*.{yml,rb,erb}")].map { |path| File.read(path) }
      sources.flat_map { |source| source.scan(PLAIN).flatten }.to_set +
        Rails.root.join("bin/falcon").read.scan(/\$\{([A-Z][A-Z0-9_]*):-/).flatten
    end

    def documented
      Rails.root.join(".env.example").readlines.filter_map { |line| line[/\A(?:# )?([A-Z][A-Z0-9_]*)=/, 1] }.to_set
    end

    def settings_listed
      Rails.root.join(".env.example").readlines.filter_map { |line| line[/\A([A-Z][A-Z0-9_]*)=/, 1] }.to_set
    end
end
