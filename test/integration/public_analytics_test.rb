require "test_helper"

class PublicAnalyticsTest < ActionDispatch::IntegrationTest
  setup do
    @release = Rails.application.config.x.concourse.release_line
    @site_id = Rails.application.config.x.analytics.site_id
    Rails.application.config.x.concourse.release_line = 3
    Rails.application.config.x.analytics.site_id = "public-site"
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @release
    Rails.application.config.x.analytics.site_id = @site_id
  end

  test "configured signed-out pages count visits without recording a session or sharing identity" do
    [ sign_in_path, join_path, terms_path, privacy_path ].each do |path|
      get path
      assert_response :success
      assert_select "script[src=?][data-site-id=public-site][data-replay-sample-rate='0'][data-turbo-track=reload]", "https://rybbit.example.com/api/script.js", count: 1
      assert_select "script[data-replay-mask-all-inputs=false]", count: 0
      assert_select "body[data-turbo=false][data-controller=ahoy]", count: 1
      assert_select "body[data-analytics-user-id-value], body[data-analytics-traits-value]", count: 0
    end
  end

  test "blank site id and URLs or referrers with potentially private input do not load the tag" do
    get sign_in_path, params: { continuation: "private" }
    assert_select "script[data-site-id]", count: 0

    get sign_in_path, headers: { "Referer" => "#{request.base_url}/private/tasks/private" }
    assert_select "script[data-site-id]", count: 0

    get sign_in_path, headers: { "Referer" => "https://referrer.example/" }
    assert_select "script[data-site-id=public-site]", count: 1

    Rails.application.config.x.analytics.site_id = ""
    get sign_in_path
    assert_select "script[data-site-id]", count: 0
    assert_select "body[data-turbo=false]", count: 0
  end

  test "a site id never loads the tag on member pages or the invitation picker" do
    organization = Organization.create!(name: "Test Network")
    owner = User.create!(ajent_sub: "42", handle: "owner", email: "owner@example.test")
    organization.memberships.create!(user: owner, role: :owner)
    sign_in_via_ajent(email: owner.email)
    assert_response :success

    [ organization_root_path(organization), join_path, privacy_path, invite_destination_path ].each do |path|
      get path
      assert_response :success
      assert_select "script[data-site-id]", count: 0
      assert_select "body[data-analytics-user-id-value], body[data-analytics-traits-value]", count: 0
    end
  end
end
