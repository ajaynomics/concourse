require "test_helper"

class PublicSurfaceTest < ActionDispatch::IntegrationTest
  test "the shared footer appears once on every public HTML page" do
    [ sign_in_path, join_path, terms_path, privacy_path ].each do |path|
      get path
      assert_response :success
      assert_select "footer#site_footer", count: 1 do
        assert_select "a[href=?]", terms_path, text: "Terms"
        assert_select "a[href=?]", privacy_path, text: "Privacy"
        assert_select "a[href=?]", "mailto:concourse@krishnan.ca", text: "Contact"
        assert_select "a[href='https://krishnan.ca/'][rel=noopener][aria-label='Ajay Krishnan'] svg path[fill=currentColor]"
      end
    end
  end

  test "new public route names cannot be claimed by an organization" do
    %w[terms privacy sitemap robots social-card sign_in sign_out].each do |slug|
      organization = Organization.new(name: "Example", slug: slug)
      assert_not organization.valid?, slug
      assert_includes organization.errors[:slug], "is reserved"
    end
    assert_not_equal "terms", Organization.create!(name: "Terms").slug
  end

  test "landing structured data is static and uses configured URLs" do
    get sign_in_path, params: { campaign: "not-public-content" }
    assert_select 'script[type="application/ld+json"]', count: 1 do |scripts|
      data = JSON.parse(scripts.first.text)
      assert_equal "WebApplication", data["@type"]
      assert_equal "Concourse", data["name"]
      assert_equal "#{Concourse.app_url}/sign_in", data["url"]
      assert_equal "Ajay Krishnan Professional Corporation", data.dig("publisher", "name")
      assert_not_includes scripts.first.text, "not-public-content"
      assert_nil data["aggregateRating"]
    end
  end

  test "social card is a 1200 by 630 PNG rather than a private screenshot" do
    png = Rails.public_path.join("social-card.png").binread
    assert_equal "\x89PNG\r\n\x1a\n".b, png.byteslice(0, 8)
    assert_equal [ 1200, 630 ], png.byteslice(16, 8).unpack("NN")
  end
end
