---
updated_at: 12/11/2026
---

# 0004 — Self-hosted Web Push, delivered through Oban, for group notifications

## Context

Group followers should hear about a new rolê on their phone, even with the app
closed. The app is a Phoenix + LiveView site installable as a home-screen app
(it already ships a web app manifest); there is no native app. Notifications are
for signed-in users only, since an anonymous visitor has no identity a device
could belong to (ADR-0002).

Constraints that shaped the choice:

- The CSP is same-origin for every directive, and only the `app.js` bundle may be
  loaded — no third-party scripts.
- Guests are on phones. Android delivers Web Push from the browser; iOS delivers
  it only to a site added to the home screen (iOS 16.4+).
- Sending to every follower's every device must not slow down saving an event,
  and a temporary push-service failure shouldn't lose the notification.

## Options

1. **Self-hosted Web Push (VAPID).** The browser's own `PushManager` and a
   service worker; the server encrypts and POSTs to the push service each browser
   uses (Google, Mozilla, Apple, Microsoft). No vendor, no third-party script.
2. **A hosted push service (OneSignal, Firebase).** Dashboards and retries for
   free, but their SDK is a third-party script (breaking the CSP and the
   one-bundle rule), user data leaves the app, and the feature depends on a
   vendor.

For delivery: fire-and-forget `Task`s (no dependency, but a restart drops what was
in flight) or Oban (a dependency and a table, with persistence and retries).

## Decision

**Self-hosted Web Push, delivered through Oban.**

- `web_push_elixir` (built on `Req`, the project's HTTP client) encrypts and
  sends; it sits behind the `Rolezinho.Notifications.Pusher` behaviour, so tests
  use an in-memory implementation and the sender can be replaced without touching
  the rest.
- `priv/static/sw.js` is the only service worker: it shows the notification and
  opens the rolê. It caches nothing.
- Oban runs two workers on the `push` queue: `NewEventWorker` (one per announced
  rolê, unique per event for a day) works out the devices and enqueues one
  `DeliverWorker` per device, which retries transient failures and deletes devices
  the push service reports gone.
- "Published" means a rolê becomes visible inside a group: created visible, or
  un-hidden. Moving an event into a group doesn't announce it.

## Consequences

- iPhone users must add the app to the home screen first; the bell shows how
  instead of a prompt that would fail.
- `web_push_elixir` sends with the `aesgcm` content encoding. Chrome/Android and
  Firefox accept it; Apple's push service should be verified on a real device.
  If it requires `aes128gcm`, only the `Pusher` implementation changes.
- The push endpoint is client-supplied and our server POSTs to it, so it is
  restricted to known push-service hosts (`SECURITY.md`, "Push notifications").
- Oban adds the `oban_jobs` table and a supervised process; jobs older than a
  week are pruned.
- Three production secrets (`VAPID_*`) are required at boot.
