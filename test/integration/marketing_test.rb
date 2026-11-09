require "test_helper"

class MarketingTest < ActionDispatch::IntegrationTest
  test "v3 landing explains the available product with working entry points" do
    with_release(3) do
      get sign_in_path
      assert_response :success
      assert_select "body.concourse-marketing"
      assert_select "h1", count: 1, text: /Stop being.*the\s*messenger/m
      assert_select "a[href=?]", join_path, text: /Connect with Pi/
      assert_select "form[action=?][method=post]", ajent_auth_path, count: 2
      assert_select "title", text: "Concourse · Stop being the messenger"
      assert_select "#networks", text: /no cross-network forwarding/i
      assert_select ".m-connector", text: /Pi.*Available/m
      assert_select ".m-connector-future", text: /More agents & frameworks.*Coming soon/m
      assert_select ".m-connect-note", text: /Approve sign-in.*Choose your network/m
      assert_select "#related-projects a", count: 4
      assert_select "#related-projects a[href=?]", "https://a2a-protocol.org/latest/specification/", text: /A2A/
      assert_select "#related-projects", text: /not bundled integrations or endorsements/
      assert_select ".m-disclosure", text: /typed input may be recorded/
      assert_select "video[poster][muted][playsinline][loop][preload=none]", count: 1
      assert_select "video[autoplay], video source[src]", count: 0
      assert_select "video source[data-src]", count: 2
      assert_select "#connection-caption", text: /Before:.*After:.*An illustration, not a live recording/m
      assert_select ".m-wont", text: /will not do:.*run a model/m
      assert_select ".m-commands", text: /script\/concourse-v3 install.*signup.*start/m
      assert_select "button[data-hero-film-target=toggle][hidden]"
      assert_select "footer#site_footer", count: 1
    end
  end

  test "legacy landing and guide keep their existing content" do
    with_release(1) do
      get sign_in_path
      assert_response :success
      assert_select "body.concourse-marketing", count: 0
      assert_select "h1", text: "Your agent can hand a teammate's agent a task."
      get join_path
      assert_response :success
      assert_select "h1", text: "Join Concourse"
      assert_select "article", text: /MCP/
      assert_select "article", text: /Setup currently requires an operator/, count: 0
    end
  end

  test "v3 guide never routes a new connector into legacy onboarding" do
    with_release(3) do
      get join_path
      assert_response :success
      assert_select "h1", text: "Connect your agents"
      assert_select "article", text: /Setup currently requires an operator/, count: 0
      assert_select "code", text: /script\/concourse-v3 signup/
      assert_select "code", text: /script\/concourse-v3 start/
      assert_select "a[href=?]", "mailto:concourse@krishnan.ca"
      assert_select "a[href='/sign_in']"
      assert_select "a[href='https://concourse.example.com/mcp']", count: 0
      assert_select "article", text: /Native forwarding is not available/
      assert_select "article", text: /30 days after the task’s last update/
    end
  end

  test "the static film assets have a bounded payload and recognizable formats" do
    assets = Rails.root.join("app/assets/images")
    assert File.size(assets.join("connection.mp4")) < 4.megabytes
    assert File.size(assets.join("connection.webm")) < 4.megabytes
    assert File.size(assets.join("connection-poster.webp")) < 250.kilobytes
    assert_equal "ftyp", File.binread(assets.join("connection.mp4"), 8)[4, 4]
    assert_equal "RIFF", File.binread(assets.join("connection-poster.webp"), 4)
  end

  test "v3 public footer pairs the maker credit with accessible country names" do
    with_release(3) do
      [ sign_in_path, join_path, terms_path, privacy_path ].each do |path|
        get path
        assert_response :success
        assert_select "footer#site_footer.m-footer", count: 1 do
          assert_select ".m-origin .sr-only", text: "Made in Canada. Friends with the USA."
          assert_select ".m-origin [aria-hidden=true] svg", count: 2
          assert_select "a[href='https://krishnan.ca/'][rel=noopener][aria-label='Ajay Krishnan'] svg path[fill=currentColor]"
          assert_select "a[href=?]", terms_path, text: "Terms"
          assert_select "a[href=?]", privacy_path, text: "Privacy"
          assert_select "a[href=?]", "mailto:concourse@krishnan.ca", text: "Contact"
        end
      end
    end
  end


  private

  def with_release(release)
    previous = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = release
    yield
  ensure
    Rails.application.config.x.concourse.release_line = previous
  end
end
