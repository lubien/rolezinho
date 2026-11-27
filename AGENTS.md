# AGENTS.md

This file guides coding agents working in this repository. It is the index: the
detailed rules live in the documents referenced in the table below.

## What this project is

**Rolezinho** — a Phoenix + LiveView app for organizing informal get-togethers. Each
event lives at `/r/<slug>` and holds the date, location, a live attendance list, a
waitlist, and a Pix QR code. The same event ships in three formats: page, plain text
(`/r/<slug>.txt`), and calendar (`/r/<slug>/calendar.ics`).

Events can be bundled under a **group** at `/g/<slug>`. A group has a name, a
slug (immutable after creation), an optional password, and a public/hidden
visibility flag. Events inside a group don't appear on the home page — their
group does. When a group has a password, its page shows only an unlock form
until the password lands, and the events inside inherit that gate. See
`SECURITY.md` §3 before touching any of it.

**Guests never sign up.** Browsing, joining a list, unlocking, paying, leaving —
all of it anonymous. The one exception is **creation**: `POST /criar` (an event)
and `POST /g/criar` (a group) require a GitHub-authenticated session, via
Ueberauth. See ADR-0002 (`docs/decisions/0002-accounts-for-creation-only.md`)
for the reasoning. The organizer can also sign in at `/admin/login` with a
single environment password (`ADMIN_PASSWORD`) as an ops bypass that stays
orthogonal to GitHub.

This access model is the most important difference from stock Phoenix — there
is still no `current_scope`, and no per-user ownership beyond what
`created_by_user_id` narrowly grants. Read `SECURITY.md` before touching any
access surface.

Stack: Phoenix 1.8, LiveView 1.2, PostgreSQL, Tailwind v4 (tokens in the `@theme` block
of `app.css`), Tabler icons, MDEx for markdown, deployed on Fly.io.

## Read X when Y

| Read | When |
|---|---|
| `PRODUCT.md` | Deciding anything about product/UX: personas, journeys, scope, anti-references |
| `DESIGN.md` | Before any UI work: tokens (colors for both themes, typography, radii, spacing), visual principles |
| `SECURITY.md` | Before touching a route, an event, an admin surface, password-gated content, `raw(...)`, or a secret |
| `TODOS.md` | To learn the project's technical and infrastructure debt |
| `MEMORY.md` | At the start of a work session: recent discoveries not yet promoted to rules |
| `docs/flow/README.md` | Before creating or updating flow documentation |
| `docs/decisions/README.md` | Before recording (or challenging) an architecture decision |
| `.claude/rules/general.md` | Always — general development and communication preferences |
| `.claude/rules/elixir.md` | Writing any Elixir code |
| `.claude/rules/elixir-antipatterns.md` | Writing/reviewing Elixir code — code anti-patterns |
| `.claude/rules/elixir-design-antipatterns.md` | Modeling modules, contexts, and internal APIs |
| `.claude/rules/phoenix.md` | Working on controllers, contexts, the router, plugs, schemas |
| `.claude/rules/liveview.md` | Working on LiveViews, components, and HEEx templates |
| `.claude/rules/testing.md` | Writing or changing tests |
| `.claude/rules/documentation.md` | Writing or updating docs in `docs/` |
| `.claude/rules/design.md` | Before any UI work — pointer to `PRODUCT.md` and `DESIGN.md` |
| `.claude/rules/security.md` | Touching security — pointer to `SECURITY.md` |
| `.claude/skills/flow-documenter/SKILL.md` | Documenting a flow/screen/feature in `docs/flow/` |
| `.claude/skills/pr-description/SKILL.md` | Generating a PR description |
| `.claude/agents/flow-documenter.md` | Delegating the documentation of a flow |
| `.claude/commands/pr.md` | Generating the current branch's PR (`/pr`) |
| `.claude/commands/major.md` / `minor.md` / `patch.md` | Bumping the semantic version in `mix.exs` |

## Golden rules

1. **The developer owns git.** By default the developer commits: at the end of a work
   block, suggest the commit message. Only run `git commit` when the developer asks
   directly. `git push` is **always** the developer's. Never use `git stash`.
2. **Plan before code.** Every non-trivial change starts with a plan presented to the
   developer, who must approve it before implementation.
3. **Commits in English, conventional commits.** `feat:`, `fix:`, `chore:`,
   `refactor:`, `test:`, `docs:`.
4. **Conversation, PRs, docs: all in English.**
5. **No emojis** — in code, docs, commits, PRs, or conversation.
6. **Never mention AI** in commit messages, PR titles, or PR descriptions.
7. **Never duplicate a source of truth.** Short rules point to the doc where the content
   lives. If a piece of information exists in two places, one of them is wrong (or soon
   will be). Known coupled pairs: `DESIGN.md` ↔ the `@theme` block in `app.css`.

## The project's four invariants

Breaking any of these is a bug, not a style choice:

1. **User markdown renders only through `RolezinhoWeb.Markdown.render/1`.** Its
   `escape: true` in MDEx and the allowlist sanitizer together prevent stored XSS in
   the `raw(...)` calls. Never drop either layer; never create a second markdown
   rendering path. (`SECURITY.md`,
   section 1)
2. **Admin requires the plug *and* the `on_mount`.** The plug protects the HTTP request;
   the `on_mount` protects the socket connection, which doesn't pass through the
   pipeline. Either one alone leaves the surface open from the other side.
   (`SECURITY.md`, section 2)
3. **Password gating on the server.** Protected event *and group* content that reaches
   the HTML and is hidden by CSS has already leaked. On a locked group, that means
   nothing about the group renders — no name, no tab title, no event list.
   (`SECURITY.md`, section 3)
4. **Group unlock cascades; group lock gates every surface.** An unlocked group grants
   full access to every event inside it; a locked group withholds it on every surface
   (page, `.txt`, `.ics`). The evaluation lives in one place per surface — mirror it if
   you add a new one. (`SECURITY.md`, section 3, "Group passwords")

## Essential commands

```bash
mix setup              # install deps, create/migrate the DB, build assets
mix phx.server         # dev server at localhost:4000
mix test               # run all tests (creates and migrates the test DB automatically)
mix test path/to/file_test.exs   # run a single test file
mix test --failed      # re-run only the tests that failed
mix precommit          # quality: compile --warnings-as-errors, deps.unlock --unused, format, test
mix format             # format code
mix ecto.gen.migration name_in_snake_case   # generate a migration (always via the CLI)
mix ecto.reset         # drop and recreate the dev DB
mix assets.build       # compile assets (tailwind + esbuild)
```

In dev: LiveDashboard at `/dev/dashboard` and the Swoosh mailbox at `/dev/mailbox`.
Requires PostgreSQL at `localhost:5432` with user/password `postgres`.

## Memory cycle

- Session discoveries (new patterns, non-obvious solutions, project conventions) are
  recorded in `MEMORY.md`.
- Once a note proves stable and repeatable across several sessions, it is **promoted** to
  the corresponding rule in `.claude/rules/` (or to a doc in `docs/`) and removed from
  `MEMORY.md`.
- Wrong or outdated entries are corrected or removed — stale memory is worse than no
  memory.

---

# Phoenix technical guidelines

What follows are the framework's technical conventions. Where a rule below conflicts with
a rule in `.claude/rules/` or with a root doc, **the project document wins** — it knows
this codebase; the guidelines below are generic.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- **This project has no `current_scope`.** It has no user accounts: the identity assigns are `:current_admin?` (boolean) and `:unlocked_events` (MapSet of slugs), populated by `RolezinhoWeb.Plugs.Admin`. `<Layouts.app>` takes `current_admin?`, not `current_scope`. Ignore any upstream guidance about `current_scope` / `phx.gen.auth` — see `SECURITY.md` and `.claude/rules/phoenix.md`
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- `core_components.ex` imports an `<.icon name="tabler-x" class="w-5 h-5"/>` component for [Tabler icons](https://tabler.io/icons) (outline by default; `-filled` suffix for the filled variant). **Always** use the `<.icon>` component for icons, **never** use icon modules or inline SVG
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### No `current_scope` here — there is `current_user` (ADR-0002)

Creation is the only surface that requires an account. Everywhere else in the
app is anonymous by design. The identity assigns you'll see on socket and
conn are:

- `:current_admin?` (boolean, from `RolezinhoWeb.Plugs.Admin`)
- `:current_user` and `:current_user_id` (from `RolezinhoWeb.Plugs.User` — nil
  when not signed in)
- `:unlocked_events`, `:unlocked_groups` (per-slug session unlocks)
- `:participants`, `:organizer_tokens` (per-slug bearer secrets)

Before adding a `:current_scope`-shaped assign, or writing a query scoped by
the signed-in user beyond `created_by_user_id`, read ADR-0002 first. Every
other "who is the current user" check the wider Phoenix community writes
assumes `phx.gen.auth` — be suspicious when following them here.

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/rolezinho_web";

- **Always use and maintain this import syntax** in the app.css file
- **Never** use `@apply` when writing raw css
- **The design tokens live in the `@theme` block of `assets/css/app.css`** and are mirrored in `DESIGN.md` — the two are a coupled pair, change both in the same commit. Never put a raw hex/oklch value in a template. Dark theme is applied via `[data-theme="dark"]`, so a new color must be added to **both** themes
- **Write your own Tailwind-based components** — this project uses no component library (no daisyUI). Shared components live in `components/core_components.ex`
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->