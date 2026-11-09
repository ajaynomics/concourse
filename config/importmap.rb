# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
# Ships inside ahoy_matey and reaches Propshaft through the engine's
# vendor/assets. Not preloaded: analytics is never on a page's critical path.
pin "ahoy", to: "ahoy.js", preload: false # ahoy.js 0.4.5, vendored by ahoy_matey
