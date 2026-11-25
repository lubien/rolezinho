---
paths:
  - "lib/rolezinho_web/**/*.ex"
  - "lib/rolezinho_web/**/*.exs"
  - "lib/rolezinho_web/**/*.heex"
  - "test/rolezinho_web/**/*.exs"
---

# Phoenix Conventions

Rules for everything under `lib/rolezinho_web/` — controllers, plugs, router,
components, and param schemas. LiveView-specific rules (templates, streams,
navigation, performance) live in `.claude/rules/liveview.md`.

## Thin web layer

- Controllers and LiveViews orchestrate; they don't implement. An action should: read
  the assigns, parse/validate params, call a context function, and render the
  response. The same goes for `handle_event`/`handle_params`.
- Business logic, queries, validations beyond basic shape, and side effects belong in
  a context module under `lib/rolezinho/`.
- If an action (or a `handle_event`) grows beyond a single `with` chain, the logic
  probably needs to move into the context.
- **Context functions don't take `socket`, `conn`, or navigation/UI decisions.** They
  return results (`{:ok, value}` / `{:error, reason}` or domain atoms); the
  LiveView/controller decides the redirect, patch, or flash from the result. Never pass
  navigation flags through the domain layer.

## Access model: there is no signed-in user

**Read `SECURITY.md` before touching any access surface.** The summary that changes
the code you write:

- This app has **no accounts**. There is no `current_scope`, no `current_user`, no
  `user_id`. Do not write per-user ownership checks — there is no user.
- Most routes are **public and anonymous by design**: any visitor reads an event and
  writes to its list. That's the core feature, not a flaw.
- The identity assigns that do exist are `:current_admin?` (boolean) and
  `:unlocked_events` (a MapSet of slugs), populated by the
  `RolezinhoWeb.Plugs.Admin.fetch_admin/2` plug and its matching `on_mount`.
- An event's identifier is its `slug`, chosen by the admin and public in the URL. It
  authorizes nothing.

When following Phoenix ecosystem documentation or examples, be suspicious: nearly all
of it assumes `phx.gen.auth` and `current_scope`. That does not apply here.

## The admin boundary

**Every action that structurally alters or destroys an existing event is admin.
Actions on one's own attendance/payment are public. Creating an event is public.**
Classify every new action explicitly, into one of three levels:

- **Public** — any visitor: reading, joining, one's own payment check, creating.
- **Organizer** — holds that event's `organizer_token` in their session: managing
  the list of the one event they created. Not an admin.
- **Admin** — the environment password: anything that reshapes or removes an event
  that already exists (slug, capacity, status, clone, delete).

For a new admin surface, both halves are mandatory:

1. **Plug** — the route goes into the `/admin` scope with the `:admin_required`
   pipeline (`plug :require_admin`). Protects the HTTP request.
2. **`on_mount`** — the LiveView uses
   `on_mount {RolezinhoWeb.Plugs.Admin, :require_admin}` on the `live_session`.
   Protects the socket connection, which **does not pass through the plug pipeline**.

Either one alone leaves the surface open from the other side.

### Privileged events on a public surface

A socket message can be forged by any connected client. Therefore: **if a privileged
`handle_event` lives in a public LiveView, it must re-check permission inside the
handler itself.** Hiding the button in the template is not access control — the client
doesn't need the button to send the event.

### Password-gated content

When an event is password-protected, the decision to show location, description, and
names is made **on the server**, based on `:current_admin?` and `:unlocked_events`.
Never by CSS, `hidden`, or a template class: content that reaches the HTML and is
hidden visually has already leaked.

## HTTP client

Use `Req` (`:req`), already in the deps. Avoid `:httpoison`, `:tesla`, and `:httpc`.

## Anonymous input is hostile input

Since most writes carry no authentication, validation shoulders the weight
authentication would carry in another project:

- **Validate index and capacity on the server.** A slot position coming from the
  client is hostile input: check the range against the event's real capacity before
  writing.
- **Bound the size of all free text.** Without a limit, a repeated POST fills the
  column and the page.
- **Never build an atom from params** (`String.to_atom/1`) — map known strings to
  known atoms with an explicit `case`.
- **Normalize before persisting** (trim, collapse whitespace).

## Standard controller flow

Standard shape — resolve the resource → check the applicable gate → act → render. Use
`with` to chain:

```elixir
def show(conn, %{"slug" => slug}) do
  with %Event{} = event <- Events.find(slug, visibility: :public),
       :ok <- ensure_unlocked(conn, event) do
    render(conn, :show, event: event)
  end
end
```

- The slug lookup comes from the context, with the appropriate `visibility` — never
  `Repo.get` directly in the web layer.
- The password/admin gate is checked explicitly, not assumed.
- In LiveViews, the same shape applies inside `handle_params`/`handle_event`, with the
  error translated into a flash/redirect.

## Routes

- Prefer RESTful routes and `live` routes organized by resource. Avoid one-off custom
  routes.
- A state-changing route uses `POST`/`PUT`/`PATCH`/`DELETE` or a LiveView event — never
  `GET`. (A legacy `GET /admin/logout` exists for link convenience; don't use it as a
  precedent.)
- Admin routes live under the `/admin` scope. A privileged route outside it is a bug.
- Rules for navigating between `live_session`s live in `.claude/rules/liveview.md`.

## Param and form validation

- For non-trivial bodies/forms, define a params module with an Ecto schema (embedded
  schema) or use the resource's own changeset.
- Cast and validate in the params schema/changeset. Pass the validated struct (or the
  extracted fields) to the context.
- This keeps the web layer free of validation logic and produces consistent changeset
  errors that `<.input>` already handles.

## Business validations

- Schema changesets stay focused on shape and basic field validations (required,
  format, length).
- **Fields the visitor doesn't control never enter the `cast` of a public form** —
  `slug`, `status`, `password`, and `main_capacity` belong to the admin and change
  through dedicated context functions (`set_status/2`, `rename_slug/2`,
  `update_password/2`). A privileged field castable from public params is a mass
  assignment vector.
- Cross-entity rules, lifecycle rules, and anything requiring context (database
  lookups, external calls) belong in the context layer.
- The web layer doesn't validate business rules — it calls the context and translates
  the result.

## Rendering user content

An event's markdown is user-written and rendered with `raw(...)`. The invariant that
prevents XSS (`escape: true` in MDEx plus the allowlist sanitizer) and the rendering
rules live in `SECURITY.md`, section 1 — **read it before adding any `raw(...)`**.

## The three outputs

The same event ships as a page, a `.txt`, and an `.ics`. When changing an event's
information, check all three: HTML escaping doesn't protect the other two, and the
`.ics` has its own escaping rules (RFC 5545, see `SECURITY.md`, section 7).
