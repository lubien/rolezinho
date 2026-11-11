defmodule RolezinhoWeb.EventEditDetailsTest do
  @moduledoc """
  The single "Detalhes do rolê" card on the admin event edit page collects
  every text/textarea/date field for an event — title, description, local,
  date, time, price, Pix key, password, slug — and saves them with one
  button.

  Rules under test:
    * All fields live in the same `#details-form`.
    * A single click of "Salvar" persists every changed field atomically.
    * Slug rename goes through `rename_slug/2` (with its redirect + move
      semantics) *and* the rest of the fields still save on the same click.
    * The Pix key input keeps the password-manager ignore attributes.
    * The attendee list is not editable from this form.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Event.Meta
  alias Rolezinho.Events

  defp create_event(attrs) do
    defaults = %{
      "title" => "Vôlei",
      "slug" => "ee-#{System.unique_integer([:positive])}",
      "description" => "",
      "local" => "Rua Caripunas",
      "date" => "2026-08-15",
      "time" => "19:00",
      "main_size" => "3",
      "wait_size" => "0",
      "password" => "",
      "price" => "15",
      "pix_key" => "9199999999",
      "pix_key_type" => "phone"
    }

    {:ok, event} = Events.create(Map.merge(defaults, attrs), admin?: true)
    event
  end

  defp admin_conn(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:admin?, true)
  end

  # The full form's inputs collected in one map; helper to build the params.
  defp details_params(overrides) do
    defaults = %{
      "title" => "Vôlei",
      "description" => "",
      "category" => "",
      "local" => "Rua Caripunas",
      "date" => "2026-08-15",
      "time" => "19:00",
      "price" => "15",
      "pix_key" => "9199999999",
      "pix_key_type" => "phone",
      "access_code" => "",
      "slug" => "same"
    }

    %{"details" => Map.merge(defaults, overrides)}
  end

  describe "form layout" do
    setup %{conn: conn} do
      event = create_event(%{"title" => "Original"})
      {:ok, view, html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")
      %{view: view, html: html, event: event}
    end

    test "every text/textarea/date field lives in one #details-form", %{view: view} do
      for name <- ~w(title description category local date time price pix_key access_code slug) do
        assert has_element?(view, "#details-form [name='details[#{name}]']"),
               "expected #details-form to carry a control for #{name}"
      end
    end

    test "there is exactly one save button on the form", %{view: view, html: html} do
      # Count `<button type="submit">` inside the form. Also assert its label.
      matches = Regex.scan(~r|<button[^>]*type="submit"[^>]*>([^<]+)</button>|, html)
      submits_in_form = view |> element("#details-form button[type='submit']") |> render()

      assert submits_in_form =~ "Salvar"
      # Only one submit button in the form itself.
      assert length(Enum.filter(matches, fn [_, label] -> String.trim(label) =~ "Salvar" end)) >=
               1
    end

    test "the old per-section forms are gone", %{view: view} do
      # A regression here would mean I split the card back apart accidentally.
      refute has_element?(view, "#meta-form")
      refute has_element?(view, "#payment-form")
      refute has_element?(view, "#password-form")
      refute has_element?(view, "#slug-form")
      refute has_element?(view, "#raw-edit-form")
    end

    test "the inputs are pre-filled with the current values", %{event: event} = ctx do
      # Round-trip check: whatever we seeded shows up in each field.
      {:ok, _view, html} = live(admin_conn(ctx.conn), ~p"/admin/r/#{event.slug}/edit")

      assert html =~ ~s(name="details[title]") and html =~ ~s(value="Original")
      assert html =~ ~s(name="details[local]") and html =~ ~s(value="Rua Caripunas")
      assert html =~ ~s(name="details[date]") and html =~ ~s(value="2026-08-15")
      assert html =~ ~s(name="details[time]") and html =~ ~s(value="19:00")
      assert html =~ ~s(name="details[price]") and html =~ ~s(value="15")
      assert html =~ ~s(name="details[pix_key]") and html =~ ~s(value="9199999999")
      assert html =~ ~s(name="details[slug]") and html =~ ~s(value="#{event.slug}")
    end
  end

  describe "single-button save" do
    test "persists title, description, meta, payment and password in one click",
         %{conn: conn} do
      event = create_event(%{"title" => "Antes"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      view
      |> form(
        "#details-form",
        details_params(%{
          "title" => "Depois",
          "description" => "Recado novo",
          "local" => "Praia Nova",
          "date" => "2027-01-05",
          "time" => "20:30",
          "price" => "22,50",
          "pix_key" => "novo@example.com",
          "pix_key_type" => "email",
          "access_code" => "SEGREDO",
          "slug" => event.slug
        })
      )
      |> render_submit()

      reloaded = Events.find(event.slug)
      {meta, description} = Meta.extract(reloaded.header)

      assert reloaded.title == "Depois"
      assert description == "Recado novo"
      assert meta.local == "Praia Nova"
      assert meta.date == ~D[2027-01-05]
      assert meta.time == ~T[20:30:00]
      assert reloaded.price_cents == 2250
      assert reloaded.pix_key == "novo@example.com"
      assert reloaded.password == "SEGREDO"

      # The structured columns must track the meta lines in the header,
      # because the role card on the group page and the calendar exports
      # read from those columns — not from the header prose.
      assert reloaded.local == "Praia Nova"
      # 2027-01-05 20:30 BRT -> 23:30 UTC on the same day.
      assert reloaded.starts_at == ~U[2027-01-05 23:30:00Z]
    end

    test "saves and clears the category field", %{conn: conn} do
      event = create_event(%{})
      assert is_nil(event.category)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      view
      |> form(
        "#details-form",
        details_params(%{"slug" => event.slug, "category" => "Trabalho"})
      )
      |> render_submit()

      assert Events.find(event.slug).category == "Trabalho"

      # And clearing it wipes the column.
      view
      |> form("#details-form", details_params(%{"slug" => event.slug, "category" => ""}))
      |> render_submit()

      assert is_nil(Events.find(event.slug).category)
    end

    test "the category input ships the Portuguese suggestions datalist", %{conn: conn} do
      event = create_event(%{})
      {:ok, view, html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      # A single <datalist id="event-category-suggestions"> exists (LiveView
      # injects a `phx-r=""` marker on it, hence the loose selector).
      assert has_element?(view, ~s(datalist#event-category-suggestions))

      # Same four defaults as the create form (see EventNewLive).
      for suggestion <- ~w(Trabalho Networking Esportes Social) do
        assert html =~ ~s(<option value="#{suggestion}")
      end

      # And the input references the datalist.
      assert has_element?(
               view,
               ~s(input[name="details[category]"][list="event-category-suggestions"])
             )
    end

    test "clearing the date wipes the starts_at column too", %{conn: conn} do
      event = create_event(%{"date" => "2026-08-15", "time" => "19:00"})
      refute is_nil(event.starts_at)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      view
      |> form(
        "#details-form",
        details_params(%{"slug" => event.slug, "date" => "", "time" => ""})
      )
      |> render_submit()

      reloaded = Events.find(event.slug)
      assert is_nil(reloaded.starts_at)
    end

    test "empty password clears it, empty price and pix wipe them", %{conn: conn} do
      event =
        create_event(%{
          "password" => "old",
          "price" => "10",
          "pix_key" => "x@y.z",
          "pix_key_type" => "email"
        })

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      view
      |> form(
        "#details-form",
        details_params(%{
          "access_code" => "",
          "price" => "",
          "pix_key" => "",
          "slug" => event.slug
        })
      )
      |> render_submit()

      reloaded = Events.find(event.slug)
      assert reloaded.password == nil
      assert reloaded.price_cents == nil
      assert reloaded.pix_key == nil
    end

    test "empty title is rejected and none of the other fields commit", %{conn: conn} do
      event = create_event(%{"title" => "Válido", "local" => "Antes"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      html =
        view
        |> form(
          "#details-form",
          details_params(%{
            "title" => "   ",
            "local" => "Depois — não deve gravar",
            "slug" => event.slug
          })
        )
        |> render_submit()

      # The flash used to dump the raw error map ("Não deu pra salvar:
      # %{...}"); the handler now surfaces a helpful message and puts the
      # field-level error inline. Either flavor of feedback works for this
      # test's purpose: the whole changeset is still rejected.
      assert html =~ "Revisa os campos destacados" or
               html =~ "can&#39;t be blank" or
               html =~ "can't be blank"

      reloaded = Events.find(event.slug)
      assert reloaded.title == "Válido"
      {meta, _} = Meta.extract(reloaded.header)
      # Local was not written either — the whole changeset was rejected.
      assert meta.local == "Antes"
    end

    test "the attendee list survives an unrelated edit", %{conn: conn} do
      event = create_event(%{})
      {:ok, event} = Events.add_to_main(event, "Alice")

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      view
      |> form(
        "#details-form",
        details_params(%{"description" => "novo texto", "slug" => event.slug})
      )
      |> render_submit()

      reloaded = Events.find(event.slug)
      assert [%{name: "Alice"} | _] = reloaded.main_list
      assert reloaded.main_capacity == 3
    end
  end

  describe "slug rename via the same form" do
    test "changing the slug renames the event AND commits the other changes",
         %{conn: conn} do
      event = create_event(%{"title" => "Antes"})
      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      # The submit redirects to the new admin edit URL.
      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form(
          "#details-form",
          details_params(%{
            "slug" => "novo-slug",
            "title" => "Depois",
            "description" => "com novo slug"
          })
        )
        |> render_submit()

      assert to == "/admin/r/novo-slug/edit"

      # Old slug is gone, new slug exists, and the bulk changes stuck.
      assert is_nil(Events.find(event.slug))
      moved = Events.find("novo-slug")
      assert moved.title == "Depois"
      {_meta, description} = Meta.extract(moved.header)
      assert description == "com novo slug"
    end

    test "a taken slug flashes an error and does NOT commit the other changes",
         %{conn: conn} do
      taken = create_event(%{"slug" => "tomado"})
      event = create_event(%{"title" => "Ainda o mesmo"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      html =
        view
        |> form(
          "#details-form",
          details_params(%{
            "slug" => taken.slug,
            "title" => "Não deveria gravar"
          })
        )
        |> render_submit()

      assert html =~ "já está em uso"
      reloaded = Events.find(event.slug)
      # Title stayed the original because slug rename aborted the whole flow.
      assert reloaded.title == "Ainda o mesmo"
    end

    test "a malformed slug is rejected with a clear message", %{conn: conn} do
      event = create_event(%{})
      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      # Bypass the HTML5 pattern by submitting the form struct directly.
      html =
        render_submit(
          form(view, "#details-form"),
          details_params(%{"slug" => "não vale"})
        )

      assert html =~ "Slug inválido"
    end
  end

  describe "auto-retag slug when the date changes" do
    # These tests exercise the "URL follows the date" behaviour: when the user
    # picks a new date and did not touch the slug themselves, and the slug
    # ends with the current `-DD-MM` (or `-DD-MM-clonado`), we rewrite the
    # slug to end with the new `-DD-MM`. Under `-clonado`, the tail is
    # dropped rather than kept: once the date moves, the URL is about a
    # different event, not a copy of the source anymore. Any other case, the
    # slug is left exactly as the user submitted.

    defp seed_with_slug_and_date(conn, slug, date_iso, extra \\ %{}) do
      event =
        create_event(
          Map.merge(
            %{
              "slug" => slug,
              "title" => "Rolê",
              "date" => date_iso
            },
            extra
          )
        )

      # Sanity check: the event actually got stored with the date we asked
      # for — otherwise the retag tests would silently no-op.
      {meta, _} = Meta.extract(event.header)
      assert meta.date == Date.from_iso8601!(date_iso)

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")
      {view, event}
    end

    test "-DD-MM suffix is rewritten when the date changes and the slug wasn't touched",
         %{conn: conn} do
      {view, event} = seed_with_slug_and_date(conn, "meu-rolezinho-18-09", "2026-09-18")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form(
          "#details-form",
          details_params(%{"slug" => event.slug, "date" => "2026-09-22"})
        )
        |> render_submit()

      assert to == "/admin/r/meu-rolezinho-22-09/edit"
      assert Events.find("meu-rolezinho-22-09")
      assert is_nil(Events.find("meu-rolezinho-18-09"))
    end

    test "-DD-MM-clonado becomes -DD-MM (the '-clonado' tail is dropped)",
         %{conn: conn} do
      # The `-clonado` was a slug-uniqueness tail added at clone time. Once
      # the organizer moves the date, this is a different event on a
      # different day — keeping `-clonado` in the URL would be misleading.
      {view, event} = seed_with_slug_and_date(conn, "meu-rolezinho-18-09-clonado", "2026-09-18")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form(
          "#details-form",
          details_params(%{"slug" => event.slug, "date" => "2026-09-22"})
        )
        |> render_submit()

      assert to == "/admin/r/meu-rolezinho-22-09/edit"
      assert Events.find("meu-rolezinho-22-09")
      refute Events.find("meu-rolezinho-22-09-clonado")
    end

    test "a manually-changed slug beats the auto-retag", %{conn: conn} do
      {view, _event} = seed_with_slug_and_date(conn, "meu-rolezinho-18-09", "2026-09-18")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form(
          "#details-form",
          details_params(%{"slug" => "escolha-do-usuario", "date" => "2026-09-22"})
        )
        |> render_submit()

      # The user's slug wins; no `-22-09` involved.
      assert to == "/admin/r/escolha-do-usuario/edit"
    end

    test "a slug without the date pattern is left alone", %{conn: conn} do
      {view, event} = seed_with_slug_and_date(conn, "sem-tag-de-data", "2026-09-18")

      view
      |> form(
        "#details-form",
        details_params(%{"slug" => event.slug, "date" => "2026-09-22"})
      )
      |> render_submit()

      # No redirect — the slug did not change. The event is still reachable
      # under the original URL, and the date did move.
      assert Events.find("sem-tag-de-data")
      reloaded = Events.find("sem-tag-de-data")
      {meta, _} = Meta.extract(reloaded.header)
      assert meta.date == ~D[2026-09-22]
    end

    test "a -DD-MM pattern that doesn't match the current date is left alone",
         %{conn: conn} do
      # Slug says 05-05 but the actual event date is 18-09. That's not a
      # date tag we manage — keep it as is.
      {view, event} = seed_with_slug_and_date(conn, "mensagem-do-05-05", "2026-09-18")

      view
      |> form(
        "#details-form",
        details_params(%{"slug" => event.slug, "date" => "2026-09-22"})
      )
      |> render_submit()

      assert Events.find("mensagem-do-05-05")
      refute Events.find("mensagem-do-22-09")
    end

    test "no retag when the original event had no date", %{conn: conn} do
      # Slug ends in something that looks like `-DD-MM`, but the event had no
      # date stored, so we cannot know if the tail is a date tag we own —
      # leave the slug alone.
      event =
        create_event(%{
          "slug" => "tag-parecida-com-data-01-02",
          "title" => "Rolê",
          "date" => ""
        })

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      view
      |> form(
        "#details-form",
        details_params(%{"slug" => event.slug, "date" => "2026-09-22"})
      )
      |> render_submit()

      assert Events.find("tag-parecida-com-data-01-02")
    end

    test "no retag when the user clears the date", %{conn: conn} do
      {view, event} = seed_with_slug_and_date(conn, "meu-rolezinho-18-09", "2026-09-18")

      view
      |> form(
        "#details-form",
        details_params(%{"slug" => event.slug, "date" => ""})
      )
      |> render_submit()

      # We don't strip the tag — that's up to the user. The URL stays.
      assert Events.find("meu-rolezinho-18-09")
    end

    test "no retag when the date did not actually change", %{conn: conn} do
      {view, event} = seed_with_slug_and_date(conn, "meu-rolezinho-18-09", "2026-09-18")

      view
      |> form(
        "#details-form",
        details_params(%{"slug" => event.slug, "date" => "2026-09-18"})
      )
      |> render_submit()

      # Same date, same slug — no redirect and the event stays at the same URL.
      assert Events.find("meu-rolezinho-18-09")
    end
  end

  describe "live slug retag on `phx-change`" do
    # These tests exercise the live behaviour: as soon as the user edits the
    # date, the slug field must update in the same round trip (no submit
    # needed) AND a `slug-retagged` event must be pushed to the client so the
    # accent-flash animation can play. The rules about "who wins" (user vs.
    # server retag) are identical to the submit-time rules; the difference is
    # the timing.

    defp render_change_target(view, _form_id, target, params) do
      # `render_change/2` needs the full form payload with a `_target`.
      # Wrap so tests stay readable.
      render_change(view, "validate_details", %{"_target" => target, "details" => params})
    end

    defp full_details(overrides) do
      Map.merge(
        %{
          "title" => "Rolê",
          "description" => "",
          "local" => "",
          "date" => "2026-09-18",
          "time" => "",
          "price" => "",
          "pix_key" => "",
          "access_code" => "",
          "slug" => "meu-rolezinho-18-09"
        },
        overrides
      )
    end

    test "editing the date field updates the slug value in the same round trip",
         %{conn: conn} do
      event =
        create_event(%{"slug" => "meu-rolezinho-18-09", "date" => "2026-09-18"})

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      html =
        render_change_target(
          view,
          "details-form",
          ["details", "date"],
          full_details(%{"date" => "2026-09-22", "slug" => event.slug})
        )

      # The slug input's rendered value is the retagged one — no submit yet.
      assert html =~ ~s(name="details[slug]") and html =~ ~s(value="meu-rolezinho-22-09")
      # And the DB still has the old slug because we did not save.
      assert Events.find("meu-rolezinho-18-09")
      refute Events.find("meu-rolezinho-22-09")
    end

    test "a `slug-retagged` event is pushed to the client on a live retag",
         %{conn: conn} do
      event = create_event(%{"slug" => "meu-rolezinho-18-09", "date" => "2026-09-18"})
      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      render_change_target(
        view,
        "details-form",
        ["details", "date"],
        full_details(%{"date" => "2026-09-22", "slug" => event.slug})
      )

      # `push_event` from the server ends up on the LV process's mailbox in
      # tests. `assert_push_event/3` is the LiveViewTest helper for it.
      assert_push_event(view, "slug-retagged", %{slug: "meu-rolezinho-22-09"})
    end

    test "editing the date twice retags each time (uses the moving reference date)",
         %{conn: conn} do
      event = create_event(%{"slug" => "meu-rolezinho-18-09", "date" => "2026-09-18"})
      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      # First date change: -18-09 -> -22-09
      render_change_target(
        view,
        "details-form",
        ["details", "date"],
        full_details(%{"date" => "2026-09-22", "slug" => "meu-rolezinho-18-09"})
      )

      assert_push_event(view, "slug-retagged", %{slug: "meu-rolezinho-22-09"})

      # Second date change: the client sends the already-retagged slug in the
      # form payload; we should retag again -22-09 -> -25-09.
      html =
        render_change_target(
          view,
          "details-form",
          ["details", "date"],
          full_details(%{"date" => "2026-09-25", "slug" => "meu-rolezinho-22-09"})
        )

      assert_push_event(view, "slug-retagged", %{slug: "meu-rolezinho-25-09"})
      assert html =~ ~s(value="meu-rolezinho-25-09")
    end

    test "the -clonado tail is dropped on a live retag (URL no longer says 'clonado')",
         %{conn: conn} do
      event =
        create_event(%{
          "slug" => "meu-rolezinho-18-09-clonado",
          "date" => "2026-09-18"
        })

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      render_change_target(
        view,
        "details-form",
        ["details", "date"],
        full_details(%{
          "date" => "2026-09-22",
          "slug" => "meu-rolezinho-18-09-clonado"
        })
      )

      assert_push_event(view, "slug-retagged", %{slug: "meu-rolezinho-22-09"})
    end

    test "editing the slug directly disables auto-retag for the rest of the session",
         %{conn: conn} do
      event = create_event(%{"slug" => "meu-rolezinho-18-09", "date" => "2026-09-18"})
      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      # User types in the slug field — sets `slug_touched?: true`.
      render_change_target(
        view,
        "details-form",
        ["details", "slug"],
        full_details(%{"slug" => "escolha-do-usuario"})
      )

      # Now edit the date. Retag must NOT fire, and no push_event either.
      html =
        render_change_target(
          view,
          "details-form",
          ["details", "date"],
          full_details(%{"slug" => "escolha-do-usuario", "date" => "2026-09-22"})
        )

      assert html =~ ~s(value="escolha-do-usuario")
      refute_push_event(view, "slug-retagged", _payload)
    end

    test "editing an unrelated field is a passthrough (no retag, no push_event)",
         %{conn: conn} do
      event = create_event(%{"slug" => "meu-rolezinho-18-09", "date" => "2026-09-18"})
      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      render_change_target(
        view,
        "details-form",
        ["details", "title"],
        full_details(%{"title" => "Novo Título", "slug" => event.slug})
      )

      refute_push_event(view, "slug-retagged", _payload)
    end

    test "a slug without the date pattern is left alone on a live date change",
         %{conn: conn} do
      event = create_event(%{"slug" => "sem-tag-de-data", "date" => "2026-09-18"})
      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      html =
        render_change_target(
          view,
          "details-form",
          ["details", "date"],
          full_details(%{"slug" => "sem-tag-de-data", "date" => "2026-09-22"})
        )

      assert html =~ ~s(value="sem-tag-de-data")
      refute_push_event(view, "slug-retagged", _payload)
    end

    test "the animation utility is loaded via the app stylesheet" do
      # Sanity check that the class the hook toggles exists in the stylesheet
      # — without this, the fanciness would silently be nothing.
      css = File.read!("priv/static/assets/css/app.css")
      assert css =~ ".animate-flash-accent", "expected the animation class in the built CSS"
      assert css =~ "@keyframes rolezinho-flash-accent"
    end
  end

  describe "wait list controls" do
    # "Na espera" lives in the same "Vagas" card as the main-list size, and
    # both save with the same button. `wait_size > 0` maps to `wait_enabled:
    # true`, mirroring the create form's convention.

    test "the resize form carries both main and wait size inputs", %{conn: conn} do
      event = create_event(%{})
      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      assert has_element?(view, "#resize-form input[name='main_size']")
      assert has_element?(view, "#resize-form input[name='wait_size']")
    end

    test "setting wait_size to 0 disables the wait list", %{conn: conn} do
      {:ok, event} =
        Events.create(
          %{
            "title" => "T",
            "slug" => "wl-#{System.unique_integer([:positive])}",
            "main_size" => "3",
            "wait_size" => "5"
          },
          admin?: true
        )

      assert event.wait_enabled

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      view
      |> form("#resize-form", %{"main_size" => "3", "wait_size" => "0"})
      |> render_submit()

      refute Events.find(event.slug).wait_enabled
    end

    test "setting wait_size > 0 turns the wait list back on", %{conn: conn} do
      {:ok, event} =
        Events.create(
          %{
            "title" => "T",
            "slug" => "wl2-#{System.unique_integer([:positive])}",
            "main_size" => "3",
            "wait_size" => "0"
          },
          admin?: true
        )

      refute event.wait_enabled

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      view
      |> form("#resize-form", %{"main_size" => "3", "wait_size" => "3"})
      |> render_submit()

      assert Events.find(event.slug).wait_enabled
    end

    test "the wait_size input reflects the current wait_enabled state", %{conn: conn} do
      {:ok, on} =
        Events.create(
          %{
            "title" => "On",
            "slug" => "wl-on",
            "main_size" => "3",
            "wait_size" => "3"
          },
          admin?: true
        )

      {:ok, off} =
        Events.create(
          %{
            "title" => "Off",
            "slug" => "wl-off",
            "main_size" => "3",
            "wait_size" => "0"
          },
          admin?: true
        )

      {:ok, _view, on_html} = live(admin_conn(conn), ~p"/admin/r/#{on.slug}/edit")
      # Any non-zero value is fine — there is no runtime capacity for the
      # wait list, the input is a shorthand for the boolean toggle.
      refute on_html =~ ~s(name="wait_size" id="wait-size-input" value="0")

      {:ok, _view, off_html} = live(admin_conn(conn), ~p"/admin/r/#{off.slug}/edit")
      assert off_html =~ ~s(value="0")
    end

    test "an out-of-range wait_size is rejected without silently succeeding",
         %{conn: conn} do
      event = create_event(%{})
      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      html =
        view
        |> form("#resize-form", %{"main_size" => "3", "wait_size" => "999"})
        |> render_submit()

      assert html =~ "Tamanhos inválidos"
    end
  end

  describe "shared text respects wait_enabled" do
    # This is the second half of the ask: when the organizer has turned the
    # wait list off, the pasteable text the app generates should stop
    # mentioning it. `Event.to_text/3` already gates the whole `Lista de
    # reserva` + `Entrar na espera` block on `wait_enabled`; these tests
    # pin that so a refactor cannot regress it.

    alias Rolezinho.Event
    alias Rolezinho.Event.Attendee

    defp event_with_wait(enabled?) do
      %Event{
        title: "Vôlei",
        slug: "volei",
        status: :active,
        main_capacity: 3,
        main_list: [
          %Attendee{name: "Alice"},
          %Attendee{name: ""},
          %Attendee{name: ""}
        ],
        wait_enabled: enabled?,
        wait_intro: "Lista de reserva",
        wait_list: []
      }
    end

    test "wait_enabled: false hides the intro, the queue, and the CTA" do
      text = Event.to_text(event_with_wait(false), "https://x/r/volei")

      refute text =~ "Lista de reserva"
      refute text =~ "Entrar na espera"
    end

    test "wait_enabled: true does keep the intro and CTA" do
      text = Event.to_text(event_with_wait(true), "https://x/r/volei")

      assert text =~ "Lista de reserva"
      assert text =~ "Entrar na espera"
    end

    test "disabling via the edit form makes the share preview stop mentioning it",
         %{conn: conn} do
      {:ok, event} =
        Events.create(
          %{
            "title" => "Compartilhado",
            "slug" => "share-" <> Integer.to_string(System.unique_integer([:positive])),
            "main_size" => "3",
            "wait_size" => "3"
          },
          admin?: true
        )

      # Before disabling: the share preview does mention the wait list.
      {:ok, _view, before_html} = live(conn, ~p"/r/#{event.slug}")
      assert before_html =~ "Entrar na espera"

      # Disable via the edit form.
      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      view
      |> form("#resize-form", %{"main_size" => "3", "wait_size" => "0"})
      |> render_submit()

      # After disabling: the wait list block is gone from the share preview.
      {:ok, _view, after_html} = live(conn, ~p"/r/#{event.slug}")
      refute after_html =~ "Entrar na espera"
      refute after_html =~ "Lista de reserva"
    end
  end

  describe "Pix key still opts out of password managers" do
    test "carries every ignore attribute", %{conn: conn} do
      event = create_event(%{})
      {:ok, _view, html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      pix_input =
        Regex.run(~r|<input[^>]*name="details\[pix_key\]"[^>]*>|, html)
        |> List.first()

      assert pix_input, "expected a Pix key input on the edit page"

      for attr <- [
            ~s(autocomplete="off"),
            ~s(data-1p-ignore="true"),
            ~s(data-lpignore="true"),
            ~s(data-bwignore="true"),
            ~s(data-form-type="other")
          ] do
        assert pix_input =~ attr,
               "expected the Pix key input to include #{attr}, got: #{pix_input}"
      end
    end
  end
end
