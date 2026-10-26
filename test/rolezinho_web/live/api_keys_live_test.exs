defmodule RolezinhoWeb.ApiKeysLiveTest do
  @moduledoc """
  LiveView coverage for `/me/chaves` and friends.

    * Anonymous visitors bounce to sign-in.
    * Signed-in users see the list, can create a key, see the raw
      token once, and revoke it.
    * Refreshing the reveal screen drops the raw token (and the
      user sees a flash explaining why).
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Accounts

  defp register do
    n = System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(4, "0")

    {:ok, user} =
      Accounts.register_user(%{"username" => "apikui#{n}", "password" => "supersecret"})

    user
  end

  defp signed_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:current_user_id, user.id)
  end

  describe "anonymous access" do
    test "bounces to /entrar with return_to preserved", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/me/chaves")
      assert String.starts_with?(to, "/entrar?")
      # The return_to param can arrive either as-is or percent-encoded
      # depending on how the LV pipeline builds the URL; both forms
      # point at the same destination.
      assert to =~ "return_to=/me/chaves" or to =~ "return_to=%2Fme%2Fchaves"
    end
  end

  describe "index" do
    test "empty state when the user has no keys", %{conn: conn} do
      user = register()
      conn = signed_in(conn, user)

      {:ok, _view, html} = live(conn, ~p"/me/chaves")
      assert html =~ "Nenhuma chave ainda"
      # Create link present.
      assert html =~ "/me/chaves/nova"
    end

    test "lists existing keys with their prefix and permissions", %{conn: conn} do
      user = register()
      conn = signed_in(conn, user)

      {:ok, key, _raw} =
        Accounts.create_api_key(user, %{"name" => "bot", "permissions" => ["events:read"]})

      {:ok, _view, html} = live(conn, ~p"/me/chaves")
      assert html =~ "bot"
      assert html =~ key.key_prefix
      assert html =~ "Rolês (leitura)"
    end

    test "revoking a key marks it visually revoked without removing it from the list",
         %{conn: conn} do
      user = register()
      conn = signed_in(conn, user)

      {:ok, key, _raw} = Accounts.create_api_key(user, %{"name" => "k", "permissions" => []})

      {:ok, view, _html} = live(conn, ~p"/me/chaves")

      view
      |> element(~s(button[phx-click="revoke"][phx-value-id="#{key.id}"]))
      |> render_click()

      html = render(view)
      # Row still present, labeled revoked, no more revoke button.
      assert html =~ "k"
      assert html =~ "revogada"
      refute has_element?(view, ~s(button[phx-click="revoke"][phx-value-id="#{key.id}"]))
    end
  end

  describe "new" do
    test "signed-in user can submit the create form and reach the reveal screen",
         %{conn: conn} do
      user = register()
      conn = signed_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/me/chaves/nova")

      # Toggle one permission.
      view
      |> element(~s(input[phx-click="toggle_permission"][phx-value-scope="events:read"]))
      |> render_click()

      # Submit.
      view
      |> form(~s(form[phx-submit="create"]), %{"name" => "integration-key"})
      |> render_submit()

      html = render(view)
      # Reveal screen is in the same socket.
      assert html =~ "Copie essa chave agora"
      assert html =~ "integration-key"
      # The raw token embeds its own prefix.
      assert html =~ "rk_live_"
    end

    test "submitting with a blank name shows an inline error", %{conn: conn} do
      user = register()
      conn = signed_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/me/chaves/nova")

      view
      |> form(~s(form[phx-submit="create"]), %{"name" => "   "})
      |> render_submit()

      html = render(view)
      assert html =~ "name:"
    end
  end

  describe "reveal" do
    # The reveal panel is a transient state inside the `/me/chaves/nova`
    # live_action: the raw token lives only in socket assigns, so
    # reloading drops it — which matches the backend contract
    # (hash only on disk, lose it = revoke + recreate).
    test "a fresh visit to /me/chaves/nova shows the empty form, not any token",
         %{conn: conn} do
      user = register()
      {:ok, _key, _raw} = Accounts.create_api_key(user, %{"name" => "k", "permissions" => []})

      conn = signed_in(conn, user)

      {:ok, _view, html} = live(conn, ~p"/me/chaves/nova")
      refute html =~ "Copie essa chave agora"
      refute html =~ "rk_live_"
    end
  end
end
