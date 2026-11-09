module PublicMetadataTestSupport
  def with_indexing_environment(production)
    previous = Rails.env
    Rails.env = production ? "production" : "test"
    yield
  ensure
    Rails.env = previous
  end

  def with_public_app_url(url)
    previous = Rails.application.config.x.app.url
    Rails.application.config.x.app.url = url
    yield
  ensure
    Rails.application.config.x.app.url = previous
  end
end
