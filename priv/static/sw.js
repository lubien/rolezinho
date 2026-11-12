// Rolezinho service worker: shows group notifications sent by the server
// (Rolezinho.Notifications) and opens the rolê when one is tapped. It does
// nothing else — no caching, no offline mode.

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()))

self.addEventListener("push", (event) => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch (_) {
    data = {}
  }

  const title = data.title || "Rolezinho"
  event.waitUntil(
    self.registration.showNotification(title, {
      body: data.body || "",
      icon: "/images/icon-192.png",
      badge: "/images/icon-192.png",
      tag: data.tag,
      data: { url: data.url || "/" },
    })
  )
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()

  // Only ever open our own pages, whatever the payload says.
  const target = new URL(event.notification.data?.url || "/", self.location.origin)
  const url = target.origin === self.location.origin ? target.href : self.location.origin + "/"

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
      const open = windows.find((w) => w.url === url)
      return open ? open.focus() : self.clients.openWindow(url)
    })
  )
})
