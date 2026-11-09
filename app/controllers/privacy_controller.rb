class PrivacyController < ApplicationController
  def show
  end

  private

  # Rails registers an anonymous callback, not a named filter to skip.
  # Legal text must remain readable without the app's modern browser features.
  def allow_browser(**)
  end
end
