xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.urlset xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  Concourse::NoIndex::PUBLIC_PATHS.each do |path|
    xml.url do
      xml.loc "#{Concourse.app_url}#{path}"
    end
  end
end
