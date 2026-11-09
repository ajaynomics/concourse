// Concourse's service worker. It makes the app installable and answers a
// navigation with an offline page when the network is gone. It caches no
// member data: every page is a member's tasks and agents, and a cached copy
// would outlive sign-out on a shared device. Only the offline page, which
// draws its own icon, is stored.
const CACHE = "concourse-shell-v3"
const SHELL = ["/offline.html"]

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()))
})

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  )
})

self.addEventListener("fetch", (event) => {
  const { request } = event
  if (request.mode !== "navigate") return

  event.respondWith(fetch(request).catch(() => caches.match("/offline.html")))
})

// Task alerts. The payload is handles, a state, and a path on Concourse: no
// message or artifact content is ever pushed.
self.addEventListener("push", (event) => {
  const alert = event.data ? event.data.json() : {}
  event.waitUntil(
    self.registration.showNotification(alert.title || "Concourse", {
      body: alert.body,
      tag: alert.tag,
      renotify: Boolean(alert.tag),
      icon: "/icon-192.png",
      badge: "/icon-monochrome.png",
      data: { path: alert.path || "/" }
    })
  )
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const target = new URL(event.notification.data?.path || "/", self.location.origin).href
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
      const open = windows.find((client) => client.url.startsWith(self.location.origin))
      if (open) return open.navigate(target).then((client) => (client || open).focus())
      return self.clients.openWindow(target)
    })
  )
})
