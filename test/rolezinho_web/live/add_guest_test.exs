defmodule RolezinhoWeb.AddGuestTest do
  @moduledoc """
  Someone already on the list can add more people under their own identity,
  without leaving and rejoining or going through the waiting list.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Event.Attendee
  alias Rolezinho.Events

  defp event(overrides \\ %{}) do
    {:ok, event} =
      Events.create(
        Map.merge(
          %{
            "title" => "Pelada",
            "slug" => "ag-#{System.unique_integer([:positive])}",
            "main_size" => "3",
            "wait_size" => "3"
          },
          overrides
        ),
        admin?: true
      )

    event
  end

  defp member_conn(conn, event, token \\ "tok-me") do
    {:ok, _, _} = Events.add_party(event, "Eu", 1, participant_id: token)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:participants, %{event.slug => token})
  end

  defp reload(event), do: Events.find(event.slug, visibility: :any)

  defp names(list), do: list |> Enum.map(& &1.name) |> Enum.reject(&(&1 == ""))

  test "a member sees 'Adicionar mais pessoas' instead of the join button", %{conn: conn} do
    event = event()
    {:ok, view, _} = live(member_conn(conn, event), ~p"/r/#{event.slug}")

    assert has_element?(view, "#add-guest-btn")
    assert has_element?(view, "#add-guest-sheet")
    refute has_element?(view, "#join-sheet")
  end

  test "a visitor who isn't on the list doesn't get it", %{conn: conn} do
    event = event()
    {:ok, view, _} = live(conn, ~p"/r/#{event.slug}")

    refute has_element?(view, "#add-guest-btn")
    refute has_element?(view, "#add-guest-sheet")
  end

  test "added people join the list owned by whoever added them", %{conn: conn} do
    event = event()
    {:ok, view, _} = live(member_conn(conn, event), ~p"/r/#{event.slug}")

    view |> form("#add-guest-form-0", %{name: "Bia"}) |> render_submit()
    view |> form("#add-guest-form-1", %{name: "Caio"}) |> render_submit()

    event = reload(event)
    assert names(event.main_list) == ["Eu", "Bia", "Caio"]

    assert Enum.all?(
             Enum.filter(event.main_list, &(&1.name != "")),
             &Attendee.owns?(&1, "tok-me", nil)
           )
  end

  test "the adder can remove someone they added", %{conn: conn} do
    event = event()
    {:ok, view, _} = live(member_conn(conn, event), ~p"/r/#{event.slug}")
    view |> form("#add-guest-form-0", %{name: "Bia"}) |> render_submit()

    render_hook(view, "remove_main", %{"index" => "2"})

    assert names(reload(event).main_list) == ["Eu"]
  end

  test "when the main list is full, added people go to the waiting list", %{conn: conn} do
    event = event(%{"main_size" => "1"})
    {:ok, view, _} = live(member_conn(conn, event), ~p"/r/#{event.slug}")

    view |> form("#add-guest-form-0", %{name: "Bia"}) |> render_submit()

    event = reload(event)
    assert names(event.main_list) == ["Eu"]
    assert names(event.wait_list) == ["Bia"]
  end

  test "a signed-in member (owning by account) can add people too", %{conn: conn} do
    {:ok, user} =
      Rolezinho.Accounts.find_or_create_by_github(%{
        "github_id" => System.unique_integer([:positive]),
        "github_login" => "ag-user"
      })

    event = event()
    {:ok, _, _} = Events.add_party(event, "Eu", 1, user_id: user.id)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:current_user_id, user.id)

    {:ok, view, _} = live(conn, ~p"/r/#{event.slug}")
    view |> form("#add-guest-form-0", %{name: "Bia"}) |> render_submit()

    assert names(reload(event).main_list) == ["Eu", "Bia"]
  end

  test "a forged add from someone not on the list is ignored", %{conn: conn} do
    event = event()
    {:ok, view, _} = live(conn, ~p"/r/#{event.slug}")

    render_hook(view, "add_guest", %{"name" => "Intruso"})

    assert names(reload(event).main_list) == []
  end

  test "nothing is added once signups close", %{conn: conn} do
    event = event()
    conn = member_conn(conn, event)
    {:ok, _} = Events.set_status(reload(event), :payments_only)

    {:ok, view, _} = live(conn, ~p"/r/#{event.slug}")
    refute has_element?(view, "#add-guest-btn")

    render_hook(view, "add_guest", %{"name" => "Bia"})
    assert names(reload(event).main_list) == ["Eu"]
  end

  test "a blank name adds nobody", %{conn: conn} do
    event = event()
    {:ok, view, _} = live(member_conn(conn, event), ~p"/r/#{event.slug}")

    view |> form("#add-guest-form-0", %{name: "  "}) |> render_submit()

    assert names(reload(event).main_list) == ["Eu"]
  end
end
