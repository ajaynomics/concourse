// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// A refresh morphs the page into the server's copy. A fold the person
// opened or shut stays as they left it.
addEventListener("turbo:before-morph-attribute", (event) => {
  if (event.target instanceof HTMLDetailsElement && event.detail.attributeName === "open") event.preventDefault()
})

// The service worker is what makes Concourse installable and gives it an
// offline page. It caches no member data; see app/views/pwa/service-worker.js.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service-worker.js", { scope: "/" }).catch(() => {})
  })
}
