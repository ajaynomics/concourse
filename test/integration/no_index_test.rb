require "test_helper"
require_relative "../support/public_metadata"

class NoIndexTest < ActionDispatch::IntegrationTest
  include PublicMetadataTestSupport

  test "private and non-HTML responses tell crawlers not to index them" do
    [ "/up", "/robots.txt", "/a2a/nobody/nothing", "/agents", "/auth/failure", "/sitemap.xml" ].each do |path|
      get path
      assert_equal Concourse::NoIndex::HEADER, response.headers["x-robots-tag"], path
    end
  end

  test "only approved successful public HTML reads can opt out" do
    cases = [
      [ "/sign_in", "GET", 200, "text/html; charset=utf-8", true, true ],
      [ "/privacy", "HEAD", 200, "text/html", true, true ],
      [ "/join", "GET", 200, "text/html", false, false ],
      [ "/join/", "GET", 200, "text/html", true, false ],
      [ "/tenant/tasks", "GET", 200, "text/html", true, false ],
      [ "/terms", "POST", 200, "text/html", true, false ],
      [ "/terms", "GET", 200, "application/json", true, false ],
      [ "/terms", "GET", 302, "text/html", true, false ],
      [ "/terms", "GET", 401, "text/html", true, false ],
      [ "/terms", "GET", 404, "text/html", true, false ],
      [ "/terms", "GET", 500, "text/html", true, false ]
    ]
    with_indexing_environment(true) do
      cases.each do |path, method, status, type, opted_in, indexable|
        headers = { "content-type" => type }
        headers[Concourse::NoIndex::PUBLIC_HEADER] = "true" if opted_in
        app = Concourse::NoIndex.new(->(_env) { [ status, headers, [] ] })
        _, result, = app.call("PATH_INFO" => path, "REQUEST_METHOD" => method, "HTTP_X_CONCOURSE_PUBLIC_PAGE" => "true")
        assert_equal indexable ? "index, follow" : Concourse::NoIndex::HEADER, result["x-robots-tag"], [ path, method, status, type ].inspect
        assert_nil result[Concourse::NoIndex::PUBLIC_HEADER]
      end
    end
  end

  test "only the exact successful social PNG is indexable in production" do
    cases = [
      [ "/social-card.png", "GET", 200, "image/png", true ],
      [ "/social-card.png", "HEAD", 200, "image/png", true ],
      [ "/social-card.png", "POST", 200, "image/png", false ],
      [ "/social-card.png", "GET", 404, "image/png", false ],
      [ "/social-card.png", "GET", 500, "image/png", false ],
      [ "/social-card.png", "GET", 302, "image/png", false ],
      [ "/social-card.png", "GET", 200, "text/html", false ],
      [ "/other.png", "GET", 200, "image/png", false ],
      [ "/a2a/agent/card.png", "GET", 200, "image/png", false ]
    ]
    [ true, false ].each do |production|
      with_indexing_environment(production) do
        cases.each do |path, method, status, type, eligible|
          app = Concourse::NoIndex.new(->(_env) { [ status, { "content-type" => type }, [] ] })
          _, headers, = app.call("PATH_INFO" => path, "REQUEST_METHOD" => method)
          assert_equal((production && eligible ? "index, follow" : Concourse::NoIndex::HEADER), headers["x-robots-tag"])
        end
      end
    end
  end

  test "even an opted-in public response stays noindex outside production" do
    with_indexing_environment(false) do
      app = Concourse::NoIndex.new(->(_env) { [ 200, { "content-type" => "text/html", Concourse::NoIndex::PUBLIC_HEADER => "true" }, [] ] })
      _, headers, = app.call("PATH_INFO" => "/sign_in", "REQUEST_METHOD" => "GET")
      assert_equal Concourse::NoIndex::HEADER, headers["x-robots-tag"]
      assert_nil headers[Concourse::NoIndex::PUBLIC_HEADER]
    end
  end

  test "public asset cache policy never applies to other methods or unsuccessful responses" do
    [ "/robots.txt", "/social-card.png" ].each do |path|
      %w[GET HEAD POST PUT PATCH DELETE OPTIONS].product([ 200, 206, 302, 304, 400, 401, 403, 404, 500, 503 ]).each do |method, status|
        next if %w[GET HEAD].include?(method) && [ 200, 304 ].include?(status)

        [ nil, "private, no-store" ].each do |cache_control|
          headers = {}
          headers["cache-control"] = cache_control if cache_control
          app = Concourse::NoIndex.new(->(_env) { [ status, headers, [] ] })
          _, result, = app.call("PATH_INFO" => path, "REQUEST_METHOD" => method)
          assert_equal({ "cache-control" => cache_control }.compact, result.slice("cache-control"), [ path, method, status ].inspect)
        end
      end
    end
  end

  test "public asset cache policy leaves other paths and fingerprinted assets unchanged" do
    [ "/robots.txt/", "/social-card.png/", "/other.png", "/assets/application-0123456789abcdef.css", "/assets/social-card-0123456789abcdef.png" ].each do |path|
      %w[GET HEAD].product([ 200, 304 ]).each do |method, status|
        original = "public, max-age=31556952, immutable"
        app = Concourse::NoIndex.new(->(_env) { [ status, { "cache-control" => original }, [] ] })
        _, headers, = app.call("PATH_INFO" => path, "REQUEST_METHOD" => method)
        assert_equal original, headers["cache-control"], path
      end
    end
  end


  test "conditional responses preserve the stored representation's robots policy" do
    [ "/sign_in", "/privacy", "/social-card.png", "/tenant/tasks" ].each do |path|
      headers = { Concourse::NoIndex::PUBLIC_HEADER => "true" }
      app = Concourse::NoIndex.new(->(_env) { [ 304, headers, [] ] })
      _, result, = app.call("PATH_INFO" => path, "REQUEST_METHOD" => "GET")
      assert_nil result["x-robots-tag"], path
      assert_nil result[Concourse::NoIndex::PUBLIC_HEADER]
    end
  end


  test "robots allows search engines to read noindex and blocks training crawlers" do
    robots = Rails.public_path.join("robots.txt").read
    assert_includes robots, "User-agent: *\nAllow: /"
    assert_includes robots, "User-agent: GPTBot"
    assert_includes robots, "User-agent: ClaudeBot"
    assert_includes robots, "Disallow: /"
    assert_includes robots, "Sitemap: https://concourse.example.com/sitemap.xml"
  end
end
