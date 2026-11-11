defmodule RolezinhoWeb.AutoPromoteWebTest do
  @moduledoc """
  Auto-promote end to end: the hint on `/r/:slug`, leaving the list from the
  page, the toggle on the edit screen, and removal through the REST API.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Accounts
  alias Rolezinho.Accounts.ApiRateLimiter
  alias Rolezinho.Events

  defp names(list), do: list |> Enum.map(& &1.name) |> Enum.reject(&(&1 == ""))

  defp seed(overrides \\ %{}, opts \\ [admin?: true]) do
    params =
      Map.merge(
        %{
          "title" => "Pelada",
          "slug" => "apw-#{System.unique_integer([:positive])}",
          "main_size" => "2",
          "wait_size" => "3",
          "auto_promote" => "true"
        },
        overrides
      )

    {:ok, event} = Events.create(params, opts)

    Enum.reduce(~w(Ana Bia Caio), event, fn name, acc ->
      {:ok, acc, _} = Events.add_party(acc, name, 1, participant_id: "tok-#{name}")
      acc
    end)
  end

  defp reload(event), do: Events.find(event.slug, visibility: :any)

  describe "event page" do
    test "shows the hint only when the event auto-promotes", %{conn: conn} do
      on = seed()
      off = seed(%{"auto_promote" => "false"})

      {:ok, view, _} = live(conn, ~p"/r/#{on.slug}")
      assert has_element?(view, "#auto-promote-hint")

      {:ok, view, _} = live(conn, ~p"/r/#{off.slug}")
      refute has_element?(view, "#auto-promote-hint")
    end

    test "leaving the list hands the spot to the head of the queue", %{conn: conn} do
      event = seed()

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:participants, %{event.slug => "tok-Ana"})

      {:ok, view, _} = live(conn, ~p"/r/#{event.slug}")
      render_hook(view, "remove_main", %{"index" => "1"})

      event = reload(event)
      assert names(event.main_list) == ["Bia", "Caio"]
      assert event.wait_list == []
    end
  end

  describe "edit screen" do
    test "the Vagas form turns the setting on and off", %{conn: conn} do
      event = seed(%{"auto_promote" => "false"})

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:admin?, true)

      {:ok, view, _} = live(conn, ~p"/admin/r/#{event.slug}/edit")
      assert has_element?(view, "#auto-promote-input")

      view
      |> form("#resize-form", %{main_size: "2", wait_size: "3", auto_promote: "true"})
      |> render_submit()

      assert reload(event).auto_promote

      view
      |> form("#resize-form", %{main_size: "2", wait_size: "3", auto_promote: "false"})
      |> render_submit()

      refute reload(event).auto_promote
    end
  end

  describe "REST API" do
    setup do
      :ok = ApiRateLimiter.init()
      :ok = ApiRateLimiter.reset!()
      :ok
    end

    test "DELETE of a main-list participant promotes the next in line", %{conn: conn} do
      n = System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(4, "0")

      {:ok, user} =
        Accounts.register_user(%{"username" => "apw#{n}", "password" => "supersecret"})

      {:ok, _key, raw} =
        Accounts.create_api_key(user, %{"name" => "k", "permissions" => ["participants:write"]})

      event = seed(%{}, created_by_user_id: user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> delete(~p"/api/v1/events/#{event.slug}/participants/1")

      assert conn.status == 200
      assert names(reload(event).main_list) == ["Bia", "Caio"]
    end
  end
end
