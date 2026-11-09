require "test_helper"

class JoinGuideTest < ActionDispatch::IntegrationTest
  # Concourse is many organizations' product. Nothing anyone can read without
  # signing in, nor anything every organization sees, names one of them.
  # A deployment lists its own tenants' names (comma-separated) to check them.
  TENANT_WORDS = ENV.fetch("CONCOURSE_TENANT_WORDS", "riley").split(",").map(&:strip).reject(&:empty?).freeze

  test "the public pages and guides name no organization in either release" do
    release_before = Rails.application.config.x.concourse.release_line
    [ 2, 3 ].each do |release|
      Rails.application.config.x.concourse.release_line = release
      guide = release == 3 ? "JOIN-V3.md" : "JOIN.md"
      pages = { guide => Rails.root.join(guide).read }
      [ "/join", "/sign_in", "/manifest.json", "/terms", "/privacy" ].each do |path|
        get path
        assert_response :success
        pages[path] = response.body
      end
      Dir[Rails.root.join("public/*.html")].each { |file| pages[File.basename(file)] = File.read(file) }

      pages.each do |name, body|
        # The operator and canonical product origin are not a customer's tenant.
        body = body.gsub("Ajay Krishnan Professional Corporation", "")
          .gsub("concourse@krishnan.ca", "").gsub("https://www.krishnan.ca", "")
          .gsub(%(href="https://krishnan.ca/"), "").gsub(%(aria-label="Ajay Krishnan"), "") # the operator's maker's mark
          .gsub("https://concourse.krishnan.ca", "")
        TENANT_WORDS.each { |word| assert_no_match(/#{word}/i, body, "V#{release} #{name} names #{word}") }
      end
    end
  ensure
    Rails.application.config.x.concourse.release_line = release_before
  end

  test "the V3 guide diagnoses resource errors without replacing client identity" do
    release_before = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    get join_path
    assert_response :success
    assert_select "h3", text: "If the issuer reports invalid_target"
    assert_select "p", text: /invalid_target is not proof that this resource is missing from the IdP/
    assert_select "p", text: /Preserve the original client and profile/
    assert_select "p", text: /Do not switch to a v2 resource, retag a client or retry registration/
  ensure
    Rails.application.config.x.concourse.release_line = release_before
  end

  test "an organization's guide note is for its own signed-in members only" do
    acme = Organization.create!(name: "Acme")
    other = Organization.create!(name: "Other")
    User.create!(ajent_sub: "1", handle: "kim", email: "kim@acme.test", organizations: [ acme ])
    User.create!(ajent_sub: "2", handle: "lee", email: "lee@other.test", organizations: [ other ])
    acme.memberships.find_by!(user: User.find_by!(handle: "kim")).update!(role: "owner")

    sign_in_via_ajent(subject: "1", email: "kim@acme.test", name: "Kim")
    patch organization_path(acme), params: { organization: { name: "Acme", guide_note: "Say hello to **acme/helper**. <script>alert(1)</script>" } }
    assert_redirected_to edit_organization_path(acme)

    get join_path
    assert_select "aside p#guide_note_title", text: /From Acme/
    assert_select "aside strong", text: "acme/helper"
    assert_no_match(/<script>alert/, response.body)

    delete sign_out_path
    get join_path
    assert_no_match(/acme\/helper/, response.body)

    sign_in_via_ajent(subject: "2", email: "lee@other.test", name: "Lee")
    get join_path
    assert_no_match(/acme\/helper/, response.body)
  end
end
