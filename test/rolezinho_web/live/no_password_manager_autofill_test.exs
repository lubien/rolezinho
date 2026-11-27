defmodule RolezinhoWeb.NoPasswordManagerAutofillTest do
  @moduledoc """
  A field-by-field pin on which inputs must stay out of password-manager
  autofill.

  Two independent reasons show up across the app:

    * Password managers misidentify Pix keys as passwords, because Pix keys
      look opaque and live near actual password fields. A mangled Pix key
      breaks payment for the whole event.

    * The join sheet is a small popover. Even correct identity autofill
      (name from GitHub / Google profile) covers the sheet with a manager
      popup that is more disruptive than helpful, and we already prefill the
      name from the /me profile via localStorage anyway.

  For every field below, we assert the five attributes that opt the field
  out of the mainstream managers (1Password, LastPass, Bitwarden) plus the
  HTML-standard `autocomplete=\"off\"`. `data-form-type=\"other\"` is a
  1Password-specific extra hint meaning \"not a login/signup/payment form\".
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Accounts
  alias Rolezinho.Events

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

  defp admin_conn(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:admin?, true)
  end

  @ignore_attrs [
    ~s(autocomplete="off"),
    ~s(data-1p-ignore="true"),
    ~s(data-lpignore="true"),
    ~s(data-bwignore="true"),
    ~s(data-form-type="other")
  ]

  # Grab the exact input tag matching `name_pattern`, then assert every
  # ignore attribute is on it.
  defp assert_all_ignore_attrs(html, name_pattern, where) do
    input =
      Regex.run(~r|<input[^>]*name="#{name_pattern}"[^>]*>|, html)
      |> case do
        [tag | _] -> tag
        _ -> nil
      end

    assert input, "expected an input matching #{name_pattern} on #{where}"

    for attr <- @ignore_attrs do
      assert input =~ attr,
             "expected #{where} to carry #{attr} on #{name_pattern}, got: #{input}"
    end

    refute input =~ ~s(type="password"),
           "#{where}: #{name_pattern} must not be type=password"

    input
  end

  describe "Pix key" do
    test "on the event create form", %{conn: conn} do
      conn = signed_in_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/criar")
      html = view |> element("#new-event-add-payment") |> render_click()

      assert_all_ignore_attrs(html, ~S(event\[pix_key\]), "/criar")
    end

    test "on the event edit form", %{conn: conn} do
      {:ok, event} =
        Events.create(
          %{
            "title" => "T",
            "slug" => "pk-#{System.unique_integer([:positive])}",
            "main_size" => "3",
            "wait_size" => "0"
          },
          admin?: true
        )

      {:ok, _view, html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      # The edit page merges every text field into a single card, so the
      # Pix key input is named `details[pix_key]` instead of `payment[pix_key]`.
      assert_all_ignore_attrs(html, ~S(details\[pix_key\]), "/admin/r/:slug/edit")
    end
  end

  describe "join sheet name field" do
    test "on the event page", %{conn: conn} do
      {:ok, event} =
        Events.create(
          %{
            "title" => "T",
            "slug" => "jn-#{System.unique_integer([:positive])}",
            "main_size" => "3",
            "wait_size" => "0"
          },
          admin?: true
        )

      {:ok, _view, html} = live(conn, ~p"/r/#{event.slug}")

      assert_all_ignore_attrs(html, "name", "/r/:slug join sheet")
    end
  end
end
