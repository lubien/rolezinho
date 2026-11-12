defmodule RolezinhoWeb.GroupPushBellTest do
  @moduledoc """
  The bell on `/g/:slug`: anonymous visitors get the sign-in sheet, signed-in
  users follow/unfollow, and the server re-checks every step.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Accounts
  alias Rolezinho.Groups
  alias Rolezinho.Notifications

  defp group(overrides \\ %{}) do
    {:ok, group} =
      Groups.create(
        Map.merge(
          %{"name" => "Turma", "slug" => "gb-#{System.unique_integer([:positive])}"},
          overrides
        )
      )

    group
  end

  defp signed_in(conn) do
    {:ok, user} =
      Accounts.find_or_create_by_github(%{
        "github_id" => System.unique_integer([:positive]),
        "github_login" => "bell-#{System.unique_integer([:positive])}"
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:current_user_id, user.id)

    {conn, user}
  end

  defp subscription(host \\ "fcm.googleapis.com") do
    %{
      "endpoint" => "https://#{host}/fcm/send/#{System.unique_integer([:positive])}",
      "keys" => %{"p256dh" => "BPubKey", "auth" => "AuthSecret"}
    }
  end

  describe "anonymous visitor" do
    test "sees the bell, which opens the sign-in sheet with both options", %{conn: conn} do
      g = group()
      {:ok, view, _html} = live(conn, ~p"/g/#{g.slug}")

      assert has_element?(view, "#push-bell")
      refute has_element?(view, "#push-bell[phx-hook]")
      assert has_element?(view, "#push-login-sheet")

      return_to = URI.encode_www_form("/g/#{g.slug}")

      assert has_element?(
               view,
               ~s(#push-login-github[href="/auth/github?return_to=#{return_to}"])
             )

      assert has_element?(view, ~s(#push-login-email[href="/entrar?return_to=#{return_to}"]))
    end

    test "a forged follow does nothing", %{conn: conn} do
      g = group()
      {:ok, view, _html} = live(conn, ~p"/g/#{g.slug}")

      render_hook(view, "push_follow", %{"subscription" => subscription()})

      assert Rolezinho.Repo.aggregate(Rolezinho.Notifications.GroupFollow, :count) == 0
    end
  end

  describe "signed-in user" do
    test "the bell carries the hook and the public key", %{conn: conn} do
      g = group()
      {conn, _user} = signed_in(conn)
      {:ok, view, _html} = live(conn, ~p"/g/#{g.slug}")

      assert has_element?(view, ~s(#push-bell[phx-hook][data-following="false"][data-vapid-key]))
    end

    test "following registers the device; tapping again unfollows", %{conn: conn} do
      g = group()
      {conn, user} = signed_in(conn)
      {:ok, view, _html} = live(conn, ~p"/g/#{g.slug}")

      render_hook(view, "push_follow", %{"subscription" => subscription(), "user_agent" => "test"})

      assert Notifications.following?(user.id, g.id)
      assert Notifications.has_device?(user.id)
      assert has_element?(view, ~s(#push-bell[data-following="true"]))

      render_hook(view, "push_unfollow", %{})

      refute Notifications.following?(user.id, g.id)
      assert has_element?(view, ~s(#push-bell[data-following="false"]))
    end

    test "a subscription to an unknown host is refused", %{conn: conn} do
      g = group()
      {conn, user} = signed_in(conn)
      {:ok, view, _html} = live(conn, ~p"/g/#{g.slug}")

      render_hook(view, "push_follow", %{"subscription" => subscription("attacker.example")})

      refute Notifications.following?(user.id, g.id)
      refute Notifications.has_device?(user.id)
    end
  end

  test "a locked group shows no bell and no sheets", %{conn: conn} do
    g = group(%{"password" => "segredo"})
    {conn, _user} = signed_in(conn)
    {:ok, view, _html} = live(conn, ~p"/g/#{g.slug}")

    refute has_element?(view, "#push-bell")
    refute has_element?(view, "#push-login-sheet")
  end

  test "the service worker is served from the site root as JavaScript", %{conn: conn} do
    conn = get(conn, "/sw.js")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "javascript"
    assert conn.resp_body =~ "showNotification"
  end
end
