defmodule RolezinhoWeb.Api.V1.SecurityTest do
  @moduledoc """
  Dedicated security-regression suite for the REST API. Each test
  here locks in one of the invariants the API's design depends on:

    * **Secrets never leak** in response bodies: event/group
      passwords, event organizer tokens, attendee participant IDs,
      attendee / foreign user IDs.
    * **Existence is never leaked** via status-code differences:
      every unauthorized access returns `404 not_found`, identical
      to the response for a resource that doesn't exist at all.
      Only "this scope is missing from your key" gets `403`.
    * **Scope enforcement** happens before any work, including
      ownership checks \u2014 so a key lacking a scope sees `403` even
      on resources they own.
    * **Cross-user isolation**: a key for user A never surfaces
      user B's resources, even when A has a lookalike slug.
    * **Key lifecycle**: revoking a key cuts off the next request;
      deleting a user cascades to their keys; a key stolen from one
      user is NOT usable to impersonate another.
    * **Rate limiting is per-key**: a sibling key is unaffected by
      the key under attack.
    * **Response hardening**: every response carries
      `X-Content-Type-Options: nosniff` and `Cache-Control:
      private, no-store`, so no intermediary caches a response
      keyed to a specific user's data.
  """
  use RolezinhoWeb.ConnCase, async: false

  alias Rolezinho.Accounts
  alias Rolezinho.Accounts.ApiRateLimiter
  alias Rolezinho.Events
  alias Rolezinho.Groups
  alias Rolezinho.Repo

  setup do
    :ok = ApiRateLimiter.init()
    :ok = ApiRateLimiter.reset!()
    :ok
  end

  defp register do
    n = System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(4, "0")

    {:ok, user} =
      Accounts.register_user(%{"username" => "sec#{n}", "password" => "supersecret"})

    user
  end

  defp key(user, scopes) do
    {:ok, _, raw} = Accounts.create_api_key(user, %{"name" => "k", "permissions" => scopes})
    raw
  end

  defp with_auth(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp seed_event(user, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      "title" => "R#{n}",
      "slug" => "sec-ev-#{n}",
      "main_size" => "3",
      "wait_size" => "2"
    }

    {:ok, event} = Events.create(Map.merge(defaults, overrides), created_by_user_id: user.id)
    event
  end

  defp seed_group(user, overrides \\ %{}) do
    n = System.unique_integer([:positive])
    # Group names have a 3-char minimum; prefix with a word so a tiny
    # unique_integer doesn't push us under it.
    defaults = %{"name" => "Grupo-#{n}", "slug" => "sec-g-#{n}"}

    {:ok, group} = Groups.create(Map.merge(defaults, overrides), created_by_user_id: user.id)
    group
  end

  describe "secrets never leak \u2014 events" do
    test "event password is not in GET /events/:slug", %{conn: conn} do
      user = register()
      event = seed_event(user, %{"password" => "s3nha"})
      raw = key(user, ["events:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events/#{event.slug}")
      body = response(conn, 200)

      refute body =~ "s3nha"
      body_json = Jason.decode!(body)
      refute Map.has_key?(body_json, "password")
    end

    test "event organizer_token is not in GET /events/:slug", %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key(user, ["events:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events/#{event.slug}")
      body = response(conn, 200)

      # The token is a bearer secret that grants organizer rights;
      # it must never travel on the API.
      refute body =~ event.organizer_token
      refute Jason.decode!(body) |> Map.has_key?("organizer_token")
    end

    test "event password is not in POST /events response", %{conn: conn} do
      user = register()
      raw = key(user, ["events:write"])

      conn =
        conn
        |> with_auth(raw)
        |> post(~p"/api/v1/events", %{
          "title" => "x",
          "slug" => "sec-write-#{System.unique_integer([:positive])}",
          "password" => "topsecret"
        })

      body = response(conn, 201)
      refute body =~ "topsecret"
      refute Jason.decode!(body) |> Map.has_key?("password")
    end

    test "event password is not in PATCH /events/:slug response", %{conn: conn} do
      user = register()
      event = seed_event(user, %{"password" => "old"})
      raw = key(user, ["events:write"])

      conn =
        conn
        |> with_auth(raw)
        |> patch(~p"/api/v1/events/#{event.slug}", %{"password" => "new-secret"})

      body = response(conn, 200)
      refute body =~ "new-secret"
      refute body =~ "old"
      refute Jason.decode!(body) |> Map.has_key?("password")
    end

    test "created_by_user_id is not in event responses", %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key(user, ["events:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events/#{event.slug}")
      body = Jason.decode!(response(conn, 200))

      refute Map.has_key?(body, "created_by_user_id")
    end
  end

  describe "secrets never leak \u2014 groups" do
    test "group password is not in GET /groups/:slug", %{conn: conn} do
      user = register()
      group = seed_group(user, %{"password" => "s3nha-grupo"})
      raw = key(user, ["groups:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/groups/#{group.slug}")
      body = response(conn, 200)

      refute body =~ "s3nha-grupo"
      body_json = Jason.decode!(body)
      refute Map.has_key?(body_json, "password")
      # The `has_password` boolean replaces it \u2014 that's safe to leak.
      assert body_json["has_password"] == true
    end

    test "group password is not in POST /groups response", %{conn: conn} do
      user = register()
      raw = key(user, ["groups:write"])

      conn =
        conn
        |> with_auth(raw)
        |> post(~p"/api/v1/groups", %{
          "name" => "Grupo API",
          "slug" => "sec-gw-#{System.unique_integer([:positive])}",
          "password" => "topsecret-grupo"
        })

      body = response(conn, 201)
      refute body =~ "topsecret-grupo"
      refute Jason.decode!(body) |> Map.has_key?("password")
    end

    test "group password is not in PATCH /groups/:slug response", %{conn: conn} do
      user = register()
      group = seed_group(user, %{"password" => "old-grupo"})
      raw = key(user, ["groups:write"])

      conn =
        conn
        |> with_auth(raw)
        |> patch(~p"/api/v1/groups/#{group.slug}", %{"password" => "new-grupo"})

      body = response(conn, 200)
      refute body =~ "new-grupo"
      refute body =~ "old-grupo"
    end

    test "created_by_user_id is not in group responses", %{conn: conn} do
      user = register()
      group = seed_group(user)
      raw = key(user, ["groups:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/groups/#{group.slug}")
      body = Jason.decode!(response(conn, 200))

      refute Map.has_key?(body, "created_by_user_id")
    end
  end

  describe "secrets never leak \u2014 attendees" do
    test "participant_id is not in /events/:slug/participants", %{conn: conn} do
      user = register()
      event = seed_event(user)

      {:ok, event, _} =
        Events.add_party(event, "Alice", 1, participant_id: "SECRET-PARTICIPANT-TOKEN")

      raw = key(user, ["participants:read"])

      conn =
        conn
        |> with_auth(raw)
        |> get(~p"/api/v1/events/#{event.slug}/participants")

      body = response(conn, 200)
      refute body =~ "SECRET-PARTICIPANT-TOKEN"
      # Each attendee map must not carry a participant_id key.
      body_json = Jason.decode!(body)

      for row <- body_json["main"] ++ body_json["wait"] do
        refute Map.has_key?(row, "participant_id")
      end
    end

    test "attendee user_id (foreign-user id) is not in /participants", %{conn: conn} do
      owner = register()
      visitor = register()
      event = seed_event(owner)

      {:ok, event, _} =
        Events.add_party(event, "Visitor", 1,
          participant_id: "p",
          user_id: visitor.id
        )

      raw = key(owner, ["participants:read"])

      conn =
        conn
        |> with_auth(raw)
        |> get(~p"/api/v1/events/#{event.slug}/participants")

      body_json = Jason.decode!(response(conn, 200))

      # The owner can see "Visitor" is on the list, but not that
      # user id #{visitor.id} is the person behind the row \u2014 that
      # would let the owner enumerate who's a signed-in user and
      # link accounts across events.
      for row <- body_json["main"] do
        refute Map.has_key?(row, "user_id")
      end

      # And the id doesn't appear elsewhere in the response as a
      # bare integer (sanity: in case we leaked it as a serialized
      # field other than `user_id`).
      refute response(conn, 200) =~ "\"user_id\":#{visitor.id}"
    end

    test "participant_id is not in event_full response either", %{conn: conn} do
      user = register()
      event = seed_event(user)
      {:ok, event, _} = Events.add_party(event, "A", 1, participant_id: "TKN")
      raw = key(user, ["events:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events/#{event.slug}")

      refute response(conn, 200) =~ "TKN"
    end
  end

  describe "existence is never leaked (404, not 403)" do
    test "GET stranger's event and GET nonexistent event return identical status",
         %{conn: conn} do
      owner = register()
      stranger = register()
      event = seed_event(owner)
      raw = key(stranger, ["events:read"])

      c1 = conn |> with_auth(raw) |> get(~p"/api/v1/events/#{event.slug}")
      c2 = conn |> with_auth(raw) |> get(~p"/api/v1/events/not-a-slug")

      assert c1.status == 404
      assert c2.status == 404

      # Both bodies are the generic "not found" error type \u2014 no
      # content difference an attacker could use to distinguish
      # "exists but not yours" from "doesn't exist".
      assert Jason.decode!(response(c1, 404))["error"]["type"] == "not_found"
      assert Jason.decode!(response(c2, 404))["error"]["type"] == "not_found"
    end

    test "PATCH stranger's event \u2192 404", %{conn: conn} do
      owner = register()
      stranger = register()
      event = seed_event(owner)
      raw = key(stranger, ["events:write"])

      conn =
        conn
        |> with_auth(raw)
        |> patch(~p"/api/v1/events/#{event.slug}", %{"title" => "hacked"})

      assert conn.status == 404
      # And the event is untouched.
      assert Events.find(event.slug, visibility: :any).title == event.title
    end

    test "DELETE stranger's event \u2192 404 and event survives", %{conn: conn} do
      owner = register()
      stranger = register()
      event = seed_event(owner)
      raw = key(stranger, ["events:write"])

      conn = conn |> with_auth(raw) |> delete(~p"/api/v1/events/#{event.slug}")

      assert conn.status == 404
      refute Events.find(event.slug, visibility: :any) == nil
    end

    test "GET stranger's group \u2192 404", %{conn: conn} do
      owner = register()
      stranger = register()
      group = seed_group(owner)
      raw = key(stranger, ["groups:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/groups/#{group.slug}")
      assert conn.status == 404
    end

    test "GET stranger's event's participants \u2192 404", %{conn: conn} do
      owner = register()
      stranger = register()
      event = seed_event(owner)
      raw = key(stranger, ["participants:read"])

      conn =
        conn
        |> with_auth(raw)
        |> get(~p"/api/v1/events/#{event.slug}/participants")

      assert conn.status == 404
    end

    test "POST participant to stranger's event \u2192 404 (not 403)",
         %{conn: conn} do
      owner = register()
      stranger = register()
      event = seed_event(owner)
      raw = key(stranger, ["participants:write"])

      conn =
        conn
        |> with_auth(raw)
        |> post(~p"/api/v1/events/#{event.slug}/participants", %{"name" => "intruder"})

      assert conn.status == 404
      # And the event's main list is unchanged.
      reloaded = Events.find(event.slug, visibility: :any)
      names = reloaded.main_list |> Enum.map(& &1.name) |> Enum.filter(&(&1 != ""))
      assert names == []
    end
  end

  describe "scope enforcement runs before ownership" do
    # Belt-and-suspenders: even a legitimate owner trying to touch
    # their own resource with the wrong scope gets 403 immediately,
    # not an accidental success through some fast path.
    test "owner missing events:read on GET /events \u2192 403 (not 200)",
         %{conn: conn} do
      user = register()
      _ = seed_event(user)
      raw = key(user, ["groups:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events")
      assert conn.status == 403
    end

    test "owner missing events:write on PATCH \u2192 403", %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key(user, ["events:read"])

      conn = conn |> with_auth(raw) |> patch(~p"/api/v1/events/#{event.slug}", %{"title" => "x"})
      assert conn.status == 403
    end

    test "a key with zero scopes gets 403 on every scope-gated endpoint",
         %{conn: conn} do
      user = register()
      raw = key(user, [])

      for path <- [
            ~p"/api/v1/events",
            ~p"/api/v1/groups"
          ] do
        c = conn |> with_auth(raw) |> get(path)
        assert c.status == 403, "expected 403 on #{path}, got #{c.status}"
      end

      # Whoami stays reachable \u2014 it's the one endpoint that works
      # for any valid key so the client can introspect the key's
      # scopes without having to probe real resources.
      whoami = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")
      assert whoami.status == 200
    end
  end

  describe "cross-user isolation" do
    test "GET /events for user A never surfaces user B's events",
         %{conn: conn} do
      a = register()
      b = register()
      event_a = seed_event(a, %{"title" => "A-event"})
      _event_b = seed_event(b, %{"title" => "B-event"})
      raw = key(a, ["events:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events")
      body = Jason.decode!(response(conn, 200))

      titles = Enum.map(body["events"], & &1["title"])
      assert "A-event" in titles
      refute "B-event" in titles
      assert body["events"] |> length() == 1

      _ = event_a
    end

    test "GET /groups for user A never surfaces user B's groups",
         %{conn: conn} do
      a = register()
      b = register()
      _ga = seed_group(a, %{"name" => "A-group"})
      _gb = seed_group(b, %{"name" => "B-group"})
      raw = key(a, ["groups:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/groups")
      body = Jason.decode!(response(conn, 200))

      names = Enum.map(body["groups"], & &1["name"])
      assert "A-group" in names
      refute "B-group" in names
    end

    test "the platform admin flag does NOT widen API access",
         %{conn: conn} do
      # Build an admin user and a stranger with an unrelated event.
      stranger = register()
      event = seed_event(stranger, %{"title" => "Not Admin's"})

      admin = register()

      {:ok, admin} =
        Repo.get(Rolezinho.Accounts.User, admin.id)
        |> Ecto.Changeset.change(admin: true)
        |> Repo.update()

      raw = key(admin, ["events:read"])

      # Admin's /events listing shows ONLY admin's own events —
      # ADR-0002, 2026-10: there is no admin scope on the API.
      list_conn = conn |> with_auth(raw) |> get(~p"/api/v1/events")
      body = Jason.decode!(response(list_conn, 200))
      refute "Not Admin's" in Enum.map(body["events"], & &1["title"])

      # And the admin can't fetch the stranger's event directly.
      # Fresh conn — can't reuse a conn that already sent a response.
      show_conn = build_conn() |> with_auth(raw) |> get(~p"/api/v1/events/#{event.slug}")
      assert show_conn.status == 404
    end
  end

  describe "key lifecycle" do
    test "revoked key returns 401 on the very next request", %{conn: conn} do
      user = register()
      raw = key(user, ["events:read"])

      # Confirm it works.
      c1 = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")
      assert c1.status == 200

      [k] = Accounts.list_api_keys_for(user)
      {:ok, _} = Accounts.revoke_api_key(user, k.id)

      # Same raw token \u2014 now 401.
      c2 = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")
      assert c2.status == 401
    end

    test "deleting a user cascades to their API keys", %{conn: conn} do
      user = register()
      raw = key(user, ["events:read"])

      Repo.delete!(user)

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")
      assert conn.status == 401

      # And the keys table has no leftover row.
      assert Accounts.list_api_keys_for(%Rolezinho.Accounts.User{id: user.id}) == []
    end
  end

  describe "rate limiting is per-key" do
    test "burning key A's quota doesn't affect sibling key B",
         %{conn: conn} do
      user = register()
      raw_a = key(user, [])
      raw_b = key(user, [])

      # Burn through A's per-minute cap.
      for _ <- 1..60 do
        _ = conn |> with_auth(raw_a) |> get(~p"/api/v1/auth/whoami")
      end

      c_a = conn |> with_auth(raw_a) |> get(~p"/api/v1/auth/whoami")
      assert c_a.status == 429

      # Same user's second key is unaffected.
      c_b = conn |> with_auth(raw_b) |> get(~p"/api/v1/auth/whoami")
      assert c_b.status == 200
    end

    test "429 carries Retry-After and the standard rate-limit headers",
         %{conn: conn} do
      user = register()
      raw = key(user, [])

      for _ <- 1..60, do: _ = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")
      conn = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")

      assert conn.status == 429
      assert [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) > 0
      assert ["0"] = get_resp_header(conn, "x-ratelimit-remaining-minute")
    end
  end

  describe "response hardening headers" do
    test "every API response carries x-content-type-options and cache-control",
         %{conn: conn} do
      user = register()
      raw = key(user, ["events:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")

      assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
      # `private, no-store` so no shared cache (CDN, corporate proxy)
      # ever retains an API response bound to a specific user.
      [cache_control] = get_resp_header(conn, "cache-control")
      assert cache_control =~ "no-store"
      assert cache_control =~ "private"
    end

    test "401 responses carry the hardening headers too", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/auth/whoami")

      assert conn.status == 401
      assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
      [cache_control] = get_resp_header(conn, "cache-control")
      assert cache_control =~ "no-store"
    end

    test "403 responses carry the hardening headers too", %{conn: conn} do
      user = register()
      raw = key(user, [])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events")

      assert conn.status == 403
      assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
    end

    test "429 responses carry the hardening headers too", %{conn: conn} do
      user = register()
      raw = key(user, [])

      for _ <- 1..60, do: _ = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")
      conn = conn |> with_auth(raw) |> get(~p"/api/v1/auth/whoami")

      assert conn.status == 429
      assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
    end
  end

  describe "defense in depth \u2014 malformed input" do
    test "garbage index on PATCH /participants/:index \u2192 422, not 500",
         %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key(user, ["participants:write"])

      conn =
        conn
        |> with_auth(raw)
        |> patch(~p"/api/v1/events/#{event.slug}/participants/notanumber", %{"name" => "x"})

      # 404 or 422 both acceptable (never 500).
      assert conn.status in [404, 422]
    end

    test "negative index on DELETE /participants/:index \u2192 422 or 404",
         %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key(user, ["participants:write"])

      conn = conn |> with_auth(raw) |> delete(~p"/api/v1/events/#{event.slug}/participants/-1")
      assert conn.status in [404, 422]
    end
  end

  describe "scope-cross contamination" do
    # A key with `events:read` must NOT grant participants:read
    # by implication, even though the two sometimes read the same
    # underlying event struct.
    test "events:read does not grant participants:read", %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key(user, ["events:read"])

      conn =
        conn
        |> with_auth(raw)
        |> get(~p"/api/v1/events/#{event.slug}/participants")

      assert conn.status == 403
    end

    # Same for groups:read vs events:read.
    test "events:read does not grant groups:read", %{conn: conn} do
      user = register()
      raw = key(user, ["events:read"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/groups")
      assert conn.status == 403
    end

    # Write doesn't imply read \u2014 belt and suspenders.
    test "events:write alone does not grant events:read", %{conn: conn} do
      user = register()
      _ = seed_event(user)
      raw = key(user, ["events:write"])

      conn = conn |> with_auth(raw) |> get(~p"/api/v1/events")
      assert conn.status == 403
    end
  end
end
