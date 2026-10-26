defmodule RolezinhoWeb.Api.V1.WriteEndpointsTest do
  @moduledoc """
  Coverage for the write endpoints exposed by the REST API:
  create / update / delete across events, groups, participants.

  Scope-gated: a key missing the right scope gets 403 before any
  work runs. Ownership-gated: a stranger always gets 404 (never
  403 — don't reveal existence).
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
    {:ok, user} = Accounts.register_user(%{"username" => "wcl#{n}", "password" => "supersecret"})
    user
  end

  defp key_with(user, perms) do
    {:ok, _key, raw} =
      Accounts.create_api_key(user, %{"name" => "k", "permissions" => perms})

    raw
  end

  defp with_auth(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp seed_event(user, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      "title" => "Rolê #{n}",
      "slug" => "wev-#{n}",
      "main_size" => "5",
      "wait_size" => "3"
    }

    {:ok, event} = Events.create(Map.merge(defaults, overrides), created_by_user_id: user.id)
    event
  end

  describe "POST /events" do
    test "creates an event owned by the caller", %{conn: conn} do
      user = register()
      raw = key_with(user, ["events:write"])

      conn =
        conn
        |> with_auth(raw)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", %{
          "title" => "API Rolê",
          "slug" => "api-ev-#{System.unique_integer([:positive])}",
          "main_size" => "4",
          "wait_size" => "2"
        })

      assert conn.status == 201
      body = json_response(conn, 201)
      assert body["title"] == "API Rolê"
      assert body["role"] == "owner"
      assert body["main_capacity"] == 4
    end

    test "without events:write → 403", %{conn: conn} do
      user = register()
      raw = key_with(user, ["events:read"])

      conn = conn |> with_auth(raw) |> post(~p"/api/v1/events", %{"title" => "x"})
      assert conn.status == 403
    end

    test "validation error returns 422 with details", %{conn: conn} do
      user = register()
      raw = key_with(user, ["events:write"])

      conn =
        conn
        |> with_auth(raw)
        |> post(~p"/api/v1/events", %{"title" => "", "slug" => ""})

      assert conn.status == 422
      assert %{"error" => %{"type" => "validation"}} = json_response(conn, 422)
    end
  end

  describe "PATCH /events/:slug" do
    test "owner can update title, status, hidden, capacity in one call", %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key_with(user, ["events:write"])

      conn =
        conn
        |> with_auth(raw)
        |> patch(~p"/api/v1/events/#{event.slug}", %{
          "title" => "Renomeado",
          "status" => "maybe",
          "hidden" => true,
          "main_capacity" => 8
        })

      body = json_response(conn, 200)
      assert body["title"] == "Renomeado"
      assert body["status"] == "maybe"
      assert body["hidden"] == true
      assert body["main_capacity"] == 8
    end

    test "stranger → 404 (never 403, don't reveal existence)", %{conn: conn} do
      owner = register()
      stranger = register()
      event = seed_event(owner)
      raw = key_with(stranger, ["events:write"])

      conn = conn |> with_auth(raw) |> patch(~p"/api/v1/events/#{event.slug}", %{"title" => "x"})
      assert conn.status == 404
    end

    test "invalid status returns 422", %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key_with(user, ["events:write"])

      conn =
        conn
        |> with_auth(raw)
        |> patch(~p"/api/v1/events/#{event.slug}", %{"status" => "yolo"})

      assert conn.status == 422
    end
  end

  describe "DELETE /events/:slug" do
    test "owner can delete, response is 204", %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key_with(user, ["events:write"])

      conn = conn |> with_auth(raw) |> delete(~p"/api/v1/events/#{event.slug}")
      assert conn.status == 204
      assert Events.find(event.slug, visibility: :any) == nil
    end

    test "stranger → 404", %{conn: conn} do
      owner = register()
      stranger = register()
      event = seed_event(owner)
      raw = key_with(stranger, ["events:write"])

      conn = conn |> with_auth(raw) |> delete(~p"/api/v1/events/#{event.slug}")
      assert conn.status == 404
      refute Events.find(event.slug, visibility: :any) == nil
    end
  end

  describe "POST /events/:slug/participants" do
    test "owner adds a main-list attendee", %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key_with(user, ["participants:write"])

      conn =
        conn
        |> with_auth(raw)
        |> post(~p"/api/v1/events/#{event.slug}/participants", %{
          "name" => "Alice",
          "values" => %{}
        })

      body = json_response(conn, 201)
      assert [%{"name" => "Alice", "index" => 1} | _] = body["main"]
    end

    test "add to wait list via list=wait", %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key_with(user, ["participants:write"])

      conn =
        conn
        |> with_auth(raw)
        |> post(~p"/api/v1/events/#{event.slug}/participants", %{
          "name" => "Zed",
          "list" => "wait"
        })

      body = json_response(conn, 201)
      assert [%{"name" => "Zed", "index" => 1} | _] = body["wait"]
    end

    test "without participants:write → 403", %{conn: conn} do
      user = register()
      event = seed_event(user)
      raw = key_with(user, ["participants:read"])

      conn =
        conn
        |> with_auth(raw)
        |> post(~p"/api/v1/events/#{event.slug}/participants", %{"name" => "x"})

      assert conn.status == 403
    end
  end

  describe "PATCH /events/:slug/participants/:index" do
    test "owner can rename and mark paid", %{conn: conn} do
      user = register()
      event = seed_event(user)
      {:ok, event, _} = Events.add_party(event, "Original", 1, participant_id: "tok")
      raw = key_with(user, ["participants:write"])

      conn =
        conn
        |> with_auth(raw)
        |> patch(~p"/api/v1/events/#{event.slug}/participants/1", %{
          "name" => "Renamed",
          "paid" => true
        })

      body = json_response(conn, 200)
      [first | _] = body["main"]
      assert first["name"] == "Renamed"
      assert first["paid"] == true
    end
  end

  describe "DELETE /events/:slug/participants/:index" do
    test "owner can remove a row", %{conn: conn} do
      user = register()
      event = seed_event(user)
      {:ok, event, _} = Events.add_party(event, "Bye", 1, participant_id: "tok")
      raw = key_with(user, ["participants:write"])

      conn =
        conn
        |> with_auth(raw)
        |> delete(~p"/api/v1/events/#{event.slug}/participants/1")

      body = json_response(conn, 200)
      [first | _] = body["main"]
      assert first["name"] == ""
    end
  end

  describe "POST /events/:slug/participants/:index/promote" do
    test "owner can promote a wait-list row to main", %{conn: conn} do
      # Make an empty main slot available for the promote: capacity 2
      # with only Alice filled leaves slot 2 open; Events.promote/2
      # takes the wait row at index 1 (Bruno) and places it there.
      user = register()
      event = seed_event(user, %{"main_size" => "2", "wait_size" => "2"})
      {:ok, event, _} = Events.add_party(event, "Alice", 1, participant_id: "a")
      {:ok, event} = Events.add_to_wait(event, "Bruno", participant_id: "b")
      raw = key_with(user, ["participants:write"])

      conn =
        conn
        |> with_auth(raw)
        |> post(~p"/api/v1/events/#{event.slug}/participants/1/promote")

      body = json_response(conn, 200)
      main_names = Enum.map(body["main"], & &1["name"])
      assert "Alice" in main_names
      assert "Bruno" in main_names
      # And the wait list is empty now.
      assert Enum.all?(body["wait"], &(&1["name"] == ""))
    end
  end

  describe "POST /groups" do
    test "owner creates a group and gets back the summary", %{conn: conn} do
      user = register()
      raw = key_with(user, ["groups:write"])

      conn =
        conn
        |> with_auth(raw)
        |> post(~p"/api/v1/groups", %{
          "name" => "API Group",
          "slug" => "api-g-#{System.unique_integer([:positive])}",
          "password" => "sesame"
        })

      body = json_response(conn, 201)
      assert body["name"] == "API Group"
      # Password is never echoed; `has_password` flag reflects it.
      refute Map.has_key?(body, "password")
      assert body["has_password"] == true
    end

    test "without groups:write → 403", %{conn: conn} do
      user = register()
      raw = key_with(user, ["groups:read"])

      conn = conn |> with_auth(raw) |> post(~p"/api/v1/groups", %{"name" => "x"})
      assert conn.status == 403
    end
  end

  describe "PATCH /groups/:slug" do
    test "owner can rename and change password", %{conn: conn} do
      user = register()

      {:ok, group} =
        Groups.create(
          %{
            "name" => "Old Name",
            "slug" => "wg-#{System.unique_integer([:positive])}"
          },
          created_by_user_id: user.id
        )

      raw = key_with(user, ["groups:write"])

      conn =
        conn
        |> with_auth(raw)
        |> patch(~p"/api/v1/groups/#{group.slug}", %{"name" => "New Name", "password" => "x"})

      body = json_response(conn, 200)
      assert body["name"] == "New Name"
      assert body["has_password"] == true
    end

    test "stranger → 404", %{conn: conn} do
      owner = register()
      stranger = register()

      {:ok, group} =
        Groups.create(
          %{"name" => "Alheio", "slug" => "wgs-#{System.unique_integer([:positive])}"},
          created_by_user_id: owner.id
        )

      raw = key_with(stranger, ["groups:write"])

      conn = conn |> with_auth(raw) |> patch(~p"/api/v1/groups/#{group.slug}", %{"name" => "x"})
      assert conn.status == 404
    end
  end

  describe "DELETE /groups/:slug" do
    test "owner deletes a group → 204", %{conn: conn} do
      user = register()

      {:ok, group} =
        Groups.create(
          %{"name" => "Nuke", "slug" => "nk-#{System.unique_integer([:positive])}"},
          created_by_user_id: user.id
        )

      raw = key_with(user, ["groups:write"])

      conn = conn |> with_auth(raw) |> delete(~p"/api/v1/groups/#{group.slug}")
      assert conn.status == 204
      assert Groups.find(group.slug) == nil
    end
  end
end
