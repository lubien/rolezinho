defmodule RolezinhoWeb.EventNewSlugAutofillTest do
  @moduledoc """
  Behaviour tests for the auto-slugify logic on the event creation form.

  The rules, in one place:

    * Empty slug + non-empty title → slug is derived from the title.
    * Empty slug + non-empty title + set date → derived slug ends with
      `-dd-mm`.
    * Once the user has typed into the slug field themselves (even to clear
      it), auto-fill stops and the field belongs to them from then on.
    * The category text input carries a `list=` attribute pointing at a
      `<datalist>` with the four Portuguese suggestions, but stays a plain
      text input.
    * The slug field lives in the collapsed Advanced card, and the payment
      card opens on demand and resets its fields when closed.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Accounts

  defp signed_in_conn(conn) do
    {:ok, user} =
      Accounts.find_or_create_by_github(%{
        "github_id" => System.unique_integer([:positive]),
        "github_login" => "creator"
      })

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:current_user_id, user.id)
  end

  # Fires a phx-change with a single field's value, mimicking what the browser
  # sends when the user types into that field: `_target` names the field the
  # user is editing.
  defp change(view, field, value) do
    field_str = to_string(field)
    params = %{"event" => %{field_str => value}, "_target" => ["event", field_str]}
    render_change(view, "validate", params)
  end

  describe "auto-slugify" do
    setup %{conn: conn} do
      conn = signed_in_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/criar")
      %{view: view}
    end

    test "typing a title fills the slug field", %{view: view} do
      html = change(view, :title, "Vôlei ver-o-beach")
      assert html =~ ~s(value="volei-ver-o-beach")
    end

    test "strips accents (NFD normalization) and lowercases", %{view: view} do
      html = change(view, :title, "Ação de Fim de Ano")
      assert html =~ ~s(value="acao-de-fim-de-ano")
    end

    test "collapses whitespace and punctuation into single hyphens", %{view: view} do
      html = change(view, :title, "  Café: (com pão) &amp; leite!  ")
      assert html =~ ~s(value="cafe-com-pao-amp-leite")
    end

    test "appends -dd-mm when a date is set on the same change", %{view: view} do
      # Simulate the browser sending both title (from the change) and the
      # current date state — the form always posts back the full params on
      # phx-change.
      html =
        render_change(view, "validate", %{
          "_target" => ["event", "title"],
          "event" => %{"title" => "Vôlei", "date" => "2026-08-15"}
        })

      assert html =~ ~s(value="volei-15-08")
    end

    test "an invalid date is ignored, not appended", %{view: view} do
      html =
        render_change(view, "validate", %{
          "_target" => ["event", "title"],
          "event" => %{"title" => "Vôlei", "date" => "not-a-date"}
        })

      assert html =~ ~s(value="volei")
      refute html =~ ~s(value="volei-)
    end

    test "an empty title leaves the slug empty (no bare -dd-mm)", %{view: view} do
      html =
        render_change(view, "validate", %{
          "_target" => ["event", "date"],
          "event" => %{"title" => "", "date" => "2026-08-15"}
        })

      # Field is present with empty value, not "-15-08".
      refute html =~ ~s(value="-15-08")
    end

    test "typing directly into the slug field disables autofill for the rest of the session",
         %{view: view} do
      # 1. User types a title → slug is derived.
      html1 = change(view, :title, "Um Nome")
      assert html1 =~ ~s(value="um-nome")

      # 2. User then types into the slug field itself (custom value).
      change(view, :slug, "meu-link-manual")

      # 3. Editing another field (e.g. title again) must NOT overwrite the
      # user's custom slug.
      html3 =
        render_change(view, "validate", %{
          "_target" => ["event", "title"],
          "event" => %{"title" => "Outro Nome", "slug" => "meu-link-manual"}
        })

      assert html3 =~ ~s(value="meu-link-manual")
      refute html3 =~ ~s(value="outro-nome")
    end

    test "clearing the slug field is treated as a user edit — no re-autofill",
         %{view: view} do
      # Autofill once from title.
      change(view, :title, "Nome A")
      # User clears the slug field intentionally.
      change(view, :slug, "")
      # Then edits the title again.
      html =
        render_change(view, "validate", %{
          "_target" => ["event", "title"],
          "event" => %{"title" => "Nome B", "slug" => ""}
        })

      # Slug stays empty — the user asked for that by clearing it.
      refute html =~ ~s(value="nome-b")
      refute html =~ ~s(value="nome-a")
    end
  end

  describe "category suggestions" do
    setup %{conn: conn} do
      conn = signed_in_conn(conn)
      {:ok, view, html} = live(conn, ~p"/criar")
      %{view: view, html: html}
    end

    test "the datalist ships the four Portuguese suggestions", %{html: html} do
      # A datalist element with one option per suggestion.
      assert html =~ ~s(<datalist id="event-category-suggestions">)
      assert html =~ ~s(<option value="Trabalho")
      assert html =~ ~s(<option value="Networking")
      assert html =~ ~s(<option value="Esportes")
      assert html =~ ~s(<option value="Social")
    end

    test "the category input points at the datalist and stays a text field",
         %{view: view} do
      # A single input named event[category] with type=text and list=...
      assert has_element?(
               view,
               ~s(input[name="event[category]"][type="text"][list="event-category-suggestions"])
             )
    end
  end

  describe "form layout" do
    setup %{conn: conn} do
      conn = signed_in_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/criar")
      %{view: view}
    end

    test "name and description share the first card", %{view: view} do
      assert has_element?(view, ~s(#new-event-basics input[name="event[title]"]))
      assert has_element?(view, ~s(#new-event-basics textarea[name="event[description]"]))
    end

    test "location, date, time and category live in the optional card", %{view: view} do
      for field <- ~w(local date time category) do
        assert has_element?(view, ~s(#new-event-details input[name="event[#{field}]"]))
      end
    end

    test "list limits, visibility, password and link live in Advanced", %{view: view} do
      for field <- ~w(main_size wait_size auto_promote hidden access_code slug) do
        assert has_element?(view, ~s(details#new-event-advanced [name="event[#{field}]"]))
      end
    end

    test "Advanced starts collapsed and keeps the open state out of server patches",
         %{view: view} do
      refute has_element?(view, "details#new-event-advanced[open]")
      assert has_element?(view, "details#new-event-advanced[phx-mounted]")
    end
  end

  describe "payment card" do
    setup %{conn: conn} do
      conn = signed_in_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/criar")
      %{view: view}
    end

    test "starts closed, with only the add button", %{view: view} do
      assert has_element?(view, "#new-event-add-payment")
      refute has_element?(view, "#new-event-payment")
      refute has_element?(view, ~s(input[name="event[pix_key]"]))
    end

    test "the add button opens the card with the payment fields", %{view: view} do
      view |> element("#new-event-add-payment") |> render_click()

      assert has_element?(view, ~s(#new-event-payment select[name="event[split_method]"]))
      assert has_element?(view, ~s(#new-event-payment select[name="event[pix_key_type]"]))
      assert has_element?(view, ~s(#new-event-payment input[name="event[pix_key]"]))
      refute has_element?(view, "#new-event-add-payment")
    end

    test "closing the card resets its fields and keeps the rest", %{view: view} do
      view |> element("#new-event-add-payment") |> render_click()

      render_change(view, "validate", %{
        "_target" => ["event", "pix_key"],
        "event" => %{
          "title" => "Churras",
          "main_size" => "30",
          "split_method" => "total_split",
          "total" => "300",
          "pix_key_type" => "email",
          "pix_key" => "ana@example.com"
        }
      })

      view |> element("#new-event-remove-payment") |> render_click()
      refute has_element?(view, "#new-event-payment")

      view |> element("#new-event-add-payment") |> render_click()

      refute has_element?(view, ~s(input[name="event[pix_key]"][value="ana@example.com"]))
      refute has_element?(view, ~s(input[name="event[total]"]))
      assert has_element?(view, ~s(input[name="event[title]"][value="Churras"]))
      assert has_element?(view, ~s(input[name="event[main_size]"][value="30"]))
    end
  end
end
