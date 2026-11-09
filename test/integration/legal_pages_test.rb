require "test_helper"

class LegalPagesTest < ActionDispatch::IntegrationTest
  test "legal pages are public readable articles with operator contact and cross links" do
    { terms_path => [ "Terms of use", privacy_path ], privacy_path => [ "Privacy policy", terms_path ] }.each do |path, (heading, other_path)|
      get path

      assert_response :success
      assert_select "main article.prose-concourse" do
        assert_select "h1", text: heading, count: 1
        assert_select "h2", count: 8
        assert_select "section h2" do |headings|
          headings.each_with_index { |node, index| assert_match(/\A#{index + 1}\. /, node.text) }
        end
        assert_select "p", text: "Effective and last updated 7 November 2026."
        assert_select "a[href='mailto:concourse@krishnan.ca']", text: "concourse@krishnan.ca"
        assert_select "a[href='#{other_path}']"
        assert_select "footer", count: 0
      end
      assert_includes article_text, "Ajay Krishnan Professional Corporation, Toronto, Ontario, Canada"
      ENV.fetch("CONCOURSE_TENANT_WORDS", "").split(",").map(&:strip).reject(&:empty?).each { |word| assert_no_match(/#{Regexp.escape(word)}/i, article_text) }
      assert_select "a[href='#{root_path}']", text: "Back to Concourse"
    end
  end

  test "legal text remains public on an outdated browser without changing the app browser gate" do
    headers = { "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.212 Safari/537.36" }

    [ terms_path, privacy_path ].each do |path|
      get path, headers: headers
      assert_response :success
      assert_select "article h1"
    end

    get my_tasks_path(organization_slug: "concourse"), headers: headers
    assert_response :not_acceptable
  end

  test "privacy distinguishes access scopes external processing and replay from operational reports" do
    get privacy_path

    [
      "Concourse runs no model",
      "external models, tools, and providers",
      "minimal agent card is public",
      "directory, projects, and extended cards are member-only",
      "participating agents and the owners of those agents",
      "not to every directory member",
      "Being an organization owner alone does not grant access",
      "We do not currently run Rybbit analytics or session replay",
      "we will update this policy before turning it on",
      "60 seconds for a machine credential",
      "machine credentials, which name no person",
      "Each agent also has an event log",
      "full IP addresses",
      "browser and device information, referrers",
      "approximate location supplied by Cloudflare",
      "ahoy_visitor and ahoy_visit",
      "GlitchTip error reports can identify",
      "Request bodies, cookies, query strings, and local variables are excluded",
      "Cloudflare handles traffic",
      "Ajent handles sign-in",
      "at most 10 minutes"
    ].each { |disclosure| assert_includes article_text, disclosure }
  end

  test "privacy states retention exceptions and browser behaviour without a global deletion promise" do
    get privacy_path

    [
      "30 days after the task's last update",
      "does not cover account records",
      "artifacts, task events, and event-log entries",
      "analytics, operational records, or backups",
      "backup copies can remain after live task deletion",
      "no single deletion deadline",
      "web sessions last 12 hours",
      "Web Push alerts require you to turn them on and grant browser permission",
      "no message or artifact body",
      "does not create an encrypted archive",
      "caches only the offline page",
      "access to, correction of, or deletion of your information"
    ].each { |disclosure| assert_includes article_text, disclosure }
  end

  test "terms retain content rights and allocate responsibility under Ontario law" do
    get terms_path

    [
      "You keep your rights",
      "non-exclusive licence",
      "not a transfer of ownership",
      "You are responsible for the agents you connect",
      "Concourse runs no model",
      "Verify it before relying on it",
      "18 or older, or the age of majority",
      "To close your account, email us",
      "free to use today",
      "no uptime guarantee or service-level agreement",
      "as is and as available",
      "Nothing in these terms excludes liability or rights that cannot lawfully be excluded",
      "laws of Ontario and the federal laws of Canada",
      "changing the effective date above"
    ].each { |disclosure| assert_includes article_text, disclosure }
  end

  private

  def article_text
    css_select("article").text.squish
  end
end
