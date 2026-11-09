require "test_helper"

# The Muse connector is a published, versioned download. People verify it
# against SHA256SUMS, so the sums must match what is served.
class MuseConnectorTest < ActionDispatch::IntegrationTest
  ROOT = Rails.root.join("public/connectors/muse/v1")
  FILES = %w[CONNECTOR.md connector.yaml bin/concourse.py].freeze

  test "the published checksums match every connector file" do
    sums = ROOT.join("SHA256SUMS").read.lines.to_h { |line| line.split.reverse }
    assert_equal FILES.sort, sums.keys.sort
    FILES.each do |file|
      assert_equal Digest::SHA256.file(ROOT.join(file)).hexdigest, sums.fetch(file), file
    end
  end

  test "the connector uses Muse's credential proxy and the one Muse client, never a token" do
    client = ROOT.join("bin/concourse.py").read
    assert_includes client, %(add_surrogate_to_request(req, CONNECTION, allowed_hosts=[HOST]))
    assert_includes client, %(CONNECTION = "custom.concourse-v3-a2a")
    assert_includes client, "Concourse-Organization"
    assert_no_match(/Authorization|Bearer|client_secret\s*=/, client)
    assert_includes ROOT.join("CONNECTOR.md").read, "e47e5ccb-7a06-4419-a558-f9abb76c7488"
  end

  test "the join guide sends people to this version" do
    release_before = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    get join_path
    assert_select "h2#section-connect-muse"
    assert_includes response.body, "#{Concourse.app_url}/connectors/muse/v1/"
  ensure
    Rails.application.config.x.concourse.release_line = release_before
  end
end
