require "test_helper"
require_relative "../support/public_metadata"

class PublicMetadataTest < ActionDispatch::IntegrationTest
  include PublicMetadataTestSupport

  test "public pages have static metadata and trusted canonical and image URLs" do
    with_indexing_environment(true) do
      with_public_app_url("https://public.example") do
        Concourse::NoIndex::PUBLIC_PATHS.each do |path|
          get "#{path}?query=private-query", headers: { "X-Forwarded-Host" => "untrusted.example" }
          assert_response :success
          assert_equal "index, follow", response.headers["x-robots-tag"], path
          assert_nil response.headers[Concourse::NoIndex::PUBLIC_HEADER]
          assert_select "title", count: 1
          assert_select 'meta[name="description"]', count: 1
          assert_select 'meta[name="robots"][content="index, follow"]', count: 1
          assert_select 'link[rel="canonical"]' do |links|
            assert_equal "https://public.example#{path}", links.first["href"]
          end
          assert_select 'meta[property="og:url"]' do |tags|
            assert_equal "https://public.example#{path}", tags.first["content"]
          end
          assert_select 'meta[property="og:title"]', count: 1
          assert_select 'meta[property="og:description"]', count: 1
          assert_select 'meta[property="og:image"][content="https://public.example/social-card.png"]', count: 1
          assert_select 'meta[property="og:image:width"][content="1200"]', count: 1
          assert_select 'meta[property="og:image:height"][content="630"]', count: 1
          assert_select 'meta[property="og:image:type"][content="image/png"]', count: 1
          assert_select 'meta[property="og:locale"][content="en_CA"]', count: 1
          assert_select 'meta[name="twitter:card"][content="summary_large_image"]', count: 1
          assert_select 'meta[name="twitter:image"][content="https://public.example/social-card.png"]', count: 1
          assert_select "head" do |heads|
            assert_no_match(/untrusted\.example|private-query/, heads.first.to_html)
          end
          head path
          assert_response :success
          assert_equal "index, follow", response.headers["x-robots-tag"]
        end
      end
    end
  end

  test "wildcard-accepting social crawlers receive public HTML metadata" do
    with_indexing_environment(true) do
      Concourse::NoIndex::PUBLIC_PATHS.each do |path|
        headers = { "Accept" => "*/*", "User-Agent" => "facebookexternalhit/1.1" }
        get path, headers: headers
        assert_response :success
        assert_equal "text/html", response.media_type
        assert_equal "index, follow", response.headers["x-robots-tag"], path
        assert_select 'meta[property="og:image"]', count: 1
        head path, headers: headers
        assert_response :success
        assert_equal "index, follow", response.headers["x-robots-tag"], path
      end
    end
  end


  test "a request header cannot make an authenticated page public" do
    organization = Organization.create!(name: "Private organization", guide_note: "Private guide content")
    User.create!(ajent_sub: "metadata-owner", handle: "metadata-owner", email: "owner@metadata.test", organizations: [ organization ])
    sign_in_via_ajent(subject: "metadata-owner", email: "owner@metadata.test", name: "Private owner")

    with_indexing_environment(true) do
      [ "/join", organization_root_path(organization), agents_path(organization), my_tasks_path(organization), "/terms", "/privacy" ].each do |path|
        get path, headers: { "X-Concourse-Public-Page" => "true" }
        assert_response :success
        assert_equal Concourse::NoIndex::HEADER, response.headers["x-robots-tag"], path
        assert_select 'meta[name="robots"]' do |tags|
          assert_includes tags.first["content"], "noindex"
        end
        assert_select 'link[rel="canonical"]', count: 0
        assert_select 'meta[property^="og:"]', count: 0
        assert_select 'meta[name^="twitter:"]', count: 0
      end
    end
  end

  test "nonproduction public pages keep trusted metadata but forbid indexing" do
    with_indexing_environment(false) do
      with_public_app_url("https://concourse.example.com") do
        Concourse::NoIndex::PUBLIC_PATHS.each do |path|
          get "#{path}?query=private-query", headers: { "X-Forwarded-Host" => "untrusted.example" }
          assert_response :success
          assert_equal Concourse::NoIndex::HEADER, response.headers["x-robots-tag"]
          assert_select 'meta[name="robots"]' do |tags|
            assert_equal Concourse::NoIndex::HEADER, tags.first["content"]
          end
          assert_select 'link[rel="canonical"]' do |links|
            assert_equal "https://concourse.example.com#{path}", links.first["href"]
          end
          assert_select 'meta[property="og:url"]' do |tags|
            assert_equal "https://concourse.example.com#{path}", tags.first["content"]
          end
        end
      end
    end
  end

  test "social image can be fetched without noimageindex in production only" do
    [ true, false ].each do |production|
      with_indexing_environment(production) do
        [ :get, :head ].each do |method|
          public_send(method, "/social-card.png")
          assert_response :success
          assert_equal "image/png", response.media_type
          assert_equal production ? "index, follow" : Concourse::NoIndex::HEADER, response.headers["x-robots-tag"]
        end
      end
    end
  end

  test "unfingerprinted public assets have short caching on reads and revalidation" do
    [ "/robots.txt", "/social-card.png" ].each do |path|
      [ :get, :head ].each do |method|
        public_send(method, path)
        assert_response :ok
        assert_equal "public, max-age=300, must-revalidate", response.headers["cache-control"], path
        modified = response.headers["last-modified"]
        assert modified.present?
        public_send(method, path, headers: { "If-Modified-Since" => modified })
        assert_response :not_modified
        assert_equal "public, max-age=300, must-revalidate", response.headers["cache-control"], path
        assert_nil response.headers["x-robots-tag"]
      end
    end
  end


  test "revalidating the social image does not replace its indexing policy" do
    with_indexing_environment(true) do
      get "/social-card.png"
      assert_response :success
      assert_equal "index, follow", response.headers["x-robots-tag"]
      modified = response.headers["last-modified"]
      assert modified.present?
      get "/social-card.png", headers: { "If-Modified-Since" => modified }
      assert_response :not_modified
      assert_nil response.headers["x-robots-tag"]
    end
  end


  test "sitemap accepts older crawlers without starting an analytics visit" do
    assert_no_difference "Ahoy::Visit.count" do
      get "/sitemap.xml", headers: { "User-Agent" => "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)" }
      assert_response :success
      assert_equal "application/xml", response.media_type
    end
  end

  test "sitemap contains only the four public URLs from trusted configuration" do
    with_public_app_url("https://public.example") do
      get "/sitemap.xml", headers: { "X-Forwarded-Host" => "untrusted.example" }
      assert_response :success
      assert_equal "application/xml", response.media_type
      xml = Nokogiri::XML(response.body)
      assert_empty xml.errors
      assert_equal Concourse::NoIndex::PUBLIC_PATHS.map { |path| "https://public.example#{path}" }, xml.xpath("//*[local-name()='loc']").map(&:text)
      assert_empty xml.xpath("//*[local-name()='lastmod']")
    end
  end

  test "sitemap XML escapes configured URLs" do
    with_public_app_url("https://public.example/a&b") do
      get "/sitemap.xml"
      assert_response :success
      assert_includes response.body, "a&amp;b"
      assert_empty Nokogiri::XML(response.body).errors
    end
  end
end
