# Rolezinho REST API

> Audience: humans and LLMs building integrations against Rolezinho.
> This document is the full contract. If something is not here, it
> is not a stable part of the API.

Base URL: `https://<host>/api/v1`

Current version: **v1**.

## Authentication

Every request requires a bearer token:

```
Authorization: Bearer rk_live_<rest-of-key>
```

- No token or an invalid one → `401 unauthorized`.
- A revoked key → `401 unauthorized` (same shape; keys look identical
  to the API from the moment they're revoked).
- Keys have scopes (see below); a request missing the required scope
  returns `403 forbidden`.

Create and revoke keys at `/me/chaves`. The full raw key is shown
exactly once at creation; after that only its 16-character prefix
is visible. Lost it? Revoke, create another.

## Scopes

A key carries a subset of these scopes, chosen at creation time:

| Scope | Covers |
|---|---|
| `events:read` | list, get events (owned + joined) |
| `events:write` | create, update, delete events (owned only) |
| `groups:read` | list, get groups (owned only) |
| `groups:write` | create, update, delete groups (owned only) |
| `participants:read` | list participants (owned + joined) |
| `participants:write` | add/edit/remove/promote participants (owned only) |

There is no admin scope. The API never widens past the key's owner,
regardless of whether the owner is a platform admin elsewhere.

## Rate limiting

Per key, two independent windows:

- **60 requests per minute**
- **10 000 requests per day**

Both must clear. Over the cap → `429 rate_limited` with:

- `Retry-After: <seconds>` — when to try again.
- `X-RateLimit-Remaining-Minute: <n>` and `-Day: <n>` — included on
  every response, success or failure.

## Response shape

### Success

Resource endpoints return the resource JSON directly:

```json
{
  "slug": "volei-30-09",
  "title": "Vôlei",
  "...": "..."
}
```

List endpoints wrap results in a plural key:

```json
{"events": [{...}, {...}]}
{"groups": [{...}, {...}]}
```

### Error

```json
{
  "error": {
    "type": "forbidden" | "unauthorized" | "not_found" | "rate_limited" | "validation" | "not_implemented",
    "message": "Human-friendly explanation.",
    "details": {...}
  }
}
```

`details` is present on `validation` errors (as `{"fields": {...}}`)
and omitted otherwise.

### Ownership and existence

Resources you don't own return `404 not_found`, not `403`. That's
deliberate: a `403` would leak the slug's existence to a stranger.
The only `403` the API ever returns is "this scope is missing from
your key" — the key's own permissions, not an existence check.

## Endpoints

### Auth

#### `GET /auth/whoami`

Sanity check. Returns the user and the key behind the request. No
scope required.

```json
{
  "user": {"id": 1, "username": "lubien", "display_name": "Lubien"},
  "key": {
    "id": 42,
    "name": "bot-whatsapp",
    "prefix": "rk_live_abc12345",
    "permissions": ["events:read", "participants:write"]
  }
}
```

### Events

#### `GET /events`

Scope: `events:read`.

Lists events the caller owns + events they joined. Each row carries
a `role`.

```json
{
  "events": [
    {"slug": "...", "role": "owner", "...": "..."},
    {"slug": "...", "role": "participant", "...": "..."}
  ]
}
```

#### `GET /events/:slug`

Scope: `events:read`.

Full payload: summary fields + `header`, `footer`, `form_fields`,
`main`, `wait`. Caller must own the event or be a participant on it.

#### `POST /events`

Scope: `events:write`.

Body:

```json
{
  "title": "Vôlei quinta",
  "slug": "volei-quinta",
  "description": "optional",
  "local": "optional",
  "date": "2026-10-02",
  "time": "19:00",
  "category": "optional",
  "main_size": "10",
  "wait_size": "3",
  "price_cents": "1500",
  "pix_key": "optional",
  "pix_key_type": "cpf | cnpj | email | phone | random",
  "password": "optional",
  "hidden": false
}
```

The resulting event is created by the caller (`created_by_user_id`).
Returns `201` + the full event payload.

#### `PATCH /events/:slug`

Scope: `events:write`. Caller must own the event.

Partial update. Any subset of these fields may appear:

- `title`, `description`, `local`, `category`
- `status` — one of `active | maybe | payments_only | done`
- `hidden` — boolean
- `main_capacity` — positive integer (grows freely; shrinking clamps
  at the number of filled slots)
- `date`, `time`
- `pix_key`, `pix_key_type`, `price_cents`
- `password`
- `slug` — renames the slug (irreversible from the API's standpoint
  but allowed; the old URL stops working)

Returns the full event payload with the updates applied.

#### `DELETE /events/:slug`

Scope: `events:write`. Caller must own the event.

Returns `204 No Content` on success.

### Participants

#### `GET /events/:slug/participants`

Scope: `participants:read`. Owner or participant can read.

```json
{
  "main_capacity": 10,
  "wait_enabled": true,
  "wait_intro": "Lista de reserva",
  "form_fields": [{"id": "name", "label": "Nome", "...": "..."}],
  "main": [{"index": 1, "name": "Alice", "paid": true, "values": {}, "joined_at": "..."}],
  "wait": [{"index": 1, "name": "Bruno", "paid": false, "values": {}, "joined_at": "..."}]
}
```

#### `POST /events/:slug/participants`

Scope: `participants:write`. Owner only.

Body:

```json
{
  "name": "Alice",
  "values": {"camisa": "M"},
  "list": "main"
}
```

`list` defaults to `"main"`; use `"wait"` to add to the queue.
Returns the full participant tree.

#### `PATCH /events/:slug/participants/:index`

Scope: `participants:write`. Owner only.

Body (all fields optional):

```json
{
  "name": "Alice Silva",
  "values": {"camisa": "G"},
  "paid": true,
  "list": "main"
}
```

Indices are 1-based. `list` picks which list the index refers to
(defaults to `"main"`). Returns the full participant tree.

#### `DELETE /events/:slug/participants/:index`

Scope: `participants:write`. Owner only.

Query: `?list=main` or `?list=wait` (defaults to `"main"`). Returns
the full participant tree.

#### `POST /events/:slug/participants/:index/promote`

Scope: `participants:write`. Owner only.

Promotes a wait-list row (`:index` on the wait list, 1-based) into
the first open main-list slot. Returns the full participant tree.

### Groups

#### `GET /groups`

Scope: `groups:read`.

Lists groups the caller owns.

#### `GET /groups/:slug`

Scope: `groups:read`. Owner only.

```json
{
  "slug": "volei-sp",
  "name": "Vôlei SP",
  "visibility": "public",
  "has_password": true,
  "created_at": "...",
  "updated_at": "...",
  "url": "https://.../g/volei-sp"
}
```

The group's password itself is never returned — only the
`has_password` boolean.

#### `POST /groups`

Scope: `groups:write`.

Body:

```json
{
  "name": "Vôlei SP",
  "slug": "volei-sp",
  "password": "optional",
  "visibility": "public" | "hidden"
}
```

Returns `201` + the group summary. The caller becomes the owner
(`created_by_user_id`).

#### `PATCH /groups/:slug`

Scope: `groups:write`. Owner only.

Fields (all optional): `name`, `password`, `visibility`.

Slug is immutable (product rule); send a `slug` and it's ignored.

#### `DELETE /groups/:slug`

Scope: `groups:write`. Owner only.

Returns `204`. The group's events survive but are marked hidden
(the existing product behavior for group deletion).

## Content types

All request and response bodies are JSON (`application/json`).
Requests should send `Content-Type: application/json` on `POST` and
`PATCH`. Responses always carry `application/json; charset=utf-8`.

## Versioning

The URL prefix (`/api/v1`) is the version. Breaking changes land
under a new prefix; backward-compatible additions land under the
current one. There is no deprecation shim between versions — old
versions stay running for a published support window.

## What this API does NOT do (yet)

- Webhooks / change notifications. Poll for now.
- Server-sent events / realtime subscriptions.
- Bulk endpoints. One resource per request.
- OAuth / third-party apps. Only user-owned API keys.
- Password-protected group unlock flow via API. Unlock on the web.
- Admin-wide access. Keys only ever see their owner's resources.
