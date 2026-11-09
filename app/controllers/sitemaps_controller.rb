class SitemapsController < ApplicationController
  include NotAVisit

  def show
    render formats: :xml, layout: false
  end

  private

  # XML consumers need none of the signed-in app's browser features.
  def allow_browser(**)
  end
end
