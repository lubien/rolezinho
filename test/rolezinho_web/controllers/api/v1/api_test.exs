defmodule RolezinhoWeb.Api.V1.ApiTest do
  @moduledoc """
  End-to-end coverage for the REST API's read endpoints and the
  shared bearer-auth / rate-limit / scope-enforcement plumbing.

  Each test provisions a real user, an API key, builds a conn with
  the `Authorization: Bearer` header set, and exercises the real
  router pipeline — no stubbing.
  """
  use RolezinhoWeb.ConnCase, async: false

  alias Rolezinho.Accounts
  alias Rolezinho.Accounts.ApiRateLimiter
  alias Rolezinho.Events
  alias Rolezinho.Groups

  setup do
    :ok = ApiRateLimiter.init()
    :ok = ApiRateLimiter.reset!()
    :ok
  end

  defp register do
    n = System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(4, "0")

    {:ok, user} =
      Accounts.register_user(%{"username" => "apicl#{n}", "password" => "supersecret"})

    user
  end

  defp key_with(user, perms) do
    {:ok, key, raw} =
      Accounts.create_api_key(user, %{
        "name" => "k-#{Enum.join(perms, "-")}",
        "permissions" => perms
      })

    {key, raw}
  end

  defp with_auth(conn, raw_token) do
    put_req_header(conn, "authorization", "Bearer " <> raw_token)
  end

  describe "auth" do
    test "no bearer token → 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/auth/whoami")

      assert conn.status == 401
      assert %{"error" => %{"type" => "unauthorized"}} = json_response(conn, 401)
    end

    test "bogus token → 401", %{conn: conn} do
      conn =
        conn
        |> with_auth("rk_live_totally-made-up")
        |> get(~p"/api/v1/auth/whoami")

      assert conn.status == 401
    end

    test "revoked key → 401", %{conn: conn} do
      user = register()
      {key, raw} = key_with(user, ["events:read"])
      {:ok, _} = Accounts.revoke_api_key(user, key.id)

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")
      assert conn.status == 401
    end

    test "valid key → whoami echoes user + key info", %{conn: conn} do
      user = register()
      {key, raw} = key_with(user, ["events:read", "groups:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")

      assert %{
               "user" => %{"id" => uid, "username" => uname},
               "key" => %{"id" => kid, "name" => _, "prefix" => prefix, "permissions" => perms}
             } = json_response(conn, 200)

      assert uid == user.id
      assert uname == user.username
      assert kid == key.id
      assert prefix == key.key_prefix
      assert "events:read" in perms
      assert "groups:read" in perms
    end

    test "rate limiter returns 429 after the minute cap", %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, [])

      # Burn through the per-minute cap (60). The 61st hit returns 429
      # with a Retry-After header.
      for _ <- 1..60 do
        _ = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")
      end

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")

      assert conn.status == 429
      assert %{"error" => %{"type" => "rate_limited"}} = json_response(conn, 429)
      [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
    end

    test "every response carries x-ratelimit-remaining-* headers", %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, [])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")

      assert [minute] = get_resp_header(conn, "x-ratelimit-remaining-minute")
      assert [day] = get_resp_header(conn, "x-ratelimit-remaining-day")
      assert String.to_integer(minute) >= 0
      assert String.to_integer(day) >= 0
    end
  end

  describe "scope enforcement" do
    test "GET /events without events:read → 403", %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, ["groups:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events")

      assert conn.status == 403
      assert %{"error" => %{"type" => "forbidden", "message" => msg}} = json_response(conn, 403)
      assert msg =~ "events:read"
    end

    test "GET /groups without groups:read → 403", %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, ["events:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/groups")
      assert conn.status == 403
    end

    test "POST /events without events:write → 403 (and before any work runs)",
         %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, ["events:read"])

      conn = conn |> with_auth(raw) |> post(~p"/api/v1/events", %{})
      assert conn.status == 403
    end
  end

  describe "GET /events" do
    defp seed_event(user, overrides \\ %{}) do
      n = System.unique_integer([:positive])

      defaults = %{
        "title" => "Rolê #{n}",
        "slug" => "api-ev-#{n}",
        "main_size" => "3",
        "wait_size" => "0"
      }

      {:ok, event} =
        Events.create(Map.merge(defaults, overrides), created_by_user_id: user.id)

      event
    end

    test "lists owned events with role: owner", %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, ["events:read"])

      event = seed_event(user, %{"title" => "Meu Rolê"})

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events")

      assert %{"events" => events} = json_response(conn, 200)
      assert [%{"slug" => slug, "role" => "owner", "title" => "Meu Rolê"} | _] = events
      assert slug == event.slug
    end

    test "returns [] when the user owns and joined nothing", %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, ["events:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events")

      assert %{"events" => []} = json_response(conn, 200)
    end

    test "includes participated events with role: participant", %{conn: conn} do
      owner = register()
      visitor = register()
      {_key, raw} = key_with(visitor, ["events:read"])

      event = seed_event(owner, %{"title" => "Alheio"})

      # `visitor` joins the main list.
      {:ok, _, _} =
        Events.add_party(event, "Visitor", 1,
          participant_id: "tok-visitor",
          user_id: visitor.id
        )

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events")

      assert %{"events" => [row | _]} = json_response(conn, 200)
      assert row["slug"] == event.slug
      assert row["role"] == "participant"
    end
  end

  describe "GET /events/:slug" do
    test "owner can read the full payload", %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, ["events:read"])
      event = seed_event(user)

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events/#{event.slug}")

      assert %{
               "slug" => slug,
               "role" => "owner",
               "main" => main,
               "wait" => _,
               "form_fields" => fields
             } = json_response(conn, 200)

      assert slug == event.slug
      assert is_list(main)
      assert is_list(fields)
    end

    test "unknown slug → 404", %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, ["events:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events/does-not-exist")

      assert conn.status == 404
    end

    test "stranger (not owner, not participant) → 404 (never reveals existence)",
         %{conn: conn} do
      owner = register()
      stranger = register()
      event = seed_event(owner)

      {_key, raw} = key_with(stranger, ["events:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events/#{event.slug}")

      assert conn.status == 404
    end
  end

  describe "GET /events/:slug/participants" do
    test "owner receives main + wait + form_fields + capacity",
         %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, ["participants:read"])
      event = seed_event(user)

      {:ok, _, _} =
        Events.add_party(event, "Alice", 1, participant_id: "tok")

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events/#{event.slug}/participants")

      assert %{
               "main" => [%{"index" => 1, "name" => "Alice"} | _],
               "wait" => _,
               "form_fields" => _,
               "main_capacity" => _
             } = json_response(conn, 200)
    end

    test "without participants:read → 403", %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, ["events:read"])
      event = seed_event(user)

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events/#{event.slug}/participants")
      assert conn.status == 403
    end
  end

  describe "GET /groups" do
    test "lists owned groups", %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, ["groups:read"])

      {:ok, group} =
        Groups.create(
          %{"name" => "Meu grupo", "slug" => "api-g-#{System.unique_integer([:positive])}"},
          created_by_user_id: user.id
        )

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/groups")

      assert %{"groups" => groups} = json_response(conn, 200)
      slugs = Enum.map(groups, & &1["slug"])
      assert group.slug in slugs
    end

    test "stranger sees empty list (never leaks someone else's groups)",
         %{conn: conn} do
      owner = register()
      stranger = register()
      {_key, raw} = key_with(stranger, ["groups:read"])

      {:ok, _group} =
        Groups.create(
          %{"name" => "Alheio", "slug" => "alheio-#{System.unique_integer([:positive])}"},
          created_by_user_id: owner.id
        )

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/groups")
      assert %{"groups" => []} = json_response(conn, 200)
    end
  end

  describe "GET /groups/:slug" do
    test "owner can read their group", %{conn: conn} do
      user = register()
      {_key, raw} = key_with(user, ["groups:read"])

      {:ok, group} =
        Groups.create(
          %{"name" => "My Group", "slug" => "my-g-#{System.unique_integer([:positive])}"},
          created_by_user_id: user.id
        )

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/groups/#{group.slug}")

      assert %{"slug" => slug, "name" => "My Group"} = json_response(conn, 200)
      assert slug == group.slug
    end

    test "stranger → 404", %{conn: conn} do
      owner = register()
      stranger = register()
      {_key, raw} = key_with(stranger, ["groups:read"])

      {:ok, group} =
        Groups.create(
          %{"name" => "Alheio", "slug" => "alheio-s-#{System.unique_integer([:positive])}"},
          created_by_user_id: owner.id
        )

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/groups/#{group.slug}")
      assert conn.status == 404
    end
  end
end
