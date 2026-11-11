# Security

Trigger for any work affecting application security: a new route, LiveView, or event;
an action under `/admin`; content gated by an event password; rendering user-written
content; any `raw(...)`; handling a secret or credential.

**Read `SECURITY.md`** (at the root) — the single source of truth for this project's
security decisions.

Three things newcomers get wrong by assuming the ecosystem default:

1. **There is no signed-in user.** No `current_scope`, no `current_user`, no per-record
   ownership. The levels are anonymous visitor, session with an unlocked event, and
   admin via an environment password. Writing a per-user ownership check here is a
   modeling error.
2. **Anonymous writes are the feature.** Any visitor writes to a public event's list.
   The weight authentication would carry in another project falls on input validation
   and on the admin boundary.
3. **User markdown renders only through `RolezinhoWeb.Markdown.render/1`.** Its quote
   replacement, `escape: true` in Earmark, and allowlist sanitizer are each an
   invariant: `escape: true` alone lets a line starting with `<` through as raw HTML.
   Never drop a step; never create a second markdown rendering path.

Before closing out any change, check the three questions at the end of `SECURITY.md`:

1. What external content am I rendering — is it escaped?
2. Is the action I added admin or public? If admin, does it have both the plug **and**
   the `on_mount`? If it's a privileged `handle_event`, does it re-check permission in
   the handler?
3. If the content is password-gated, is the gate on the server or merely hidden in the
   template?

Don't duplicate the rules here: the admin boundary and mass assignment live in
`.claude/rules/phoenix.md`; escaping, hooks, and `textContent` in
`.claude/rules/liveview.md`. `SECURITY.md` unifies them and points to both. This rule
exists only to trigger the read.
