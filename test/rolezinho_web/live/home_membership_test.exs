defmodule RolezinhoWeb.HomeMembershipTest do
  @moduledoc """
  The home marks the viewer's own rolês (blue border + pill) and lists the
  ones they belong to, anonymous joins included.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Events
  alias Rolezinho.Groups

  defp create_event(overrides, opts \\ [admin?: true]) do
    defaults = %{
      "title" => "Rolê",
      "slug" => "hm-#{System.unique_integer([:positive])}",
      "main_size" => "3",
      "wait_size" => "2",
      "price" => "15"
    }

    {:ok, event} = Events.create(Map.merge(defaults, overrides), opts)
    event
  end

  defp device_conn(conn, participants) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:participants, participants)
  end

  defp card(slug), do: ~s(a[href="/r/#{slug}"])

  test "a public rolê I joined on this device says Participando", %{conn: conn} do
    event = create_event(%{"slug" => "hm-joined"})
    {:ok, _, _} = Events.add_party(event, "Eu", 1, participant_id: "tok-me")

    {:ok, view, _html} = live(device_conn(conn, %{event.slug => "tok-me"}), ~p"/")

    assert has_element?(view, card("hm-joined") <> ".border-info", "Participando")
  end

  test "a public rolê I'm not on keeps its usual pill", %{conn: conn} do
    create_event(%{"slug" => "hm-other"})

    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, card("hm-other") <> ".border-info")
    assert has_element?(view, card("hm-other"), "Vagas abertas")
  end

  test "a payments-only rolê I haven't paid says Caloteiro", %{conn: conn} do
    event = create_event(%{"slug" => "hm-owe"})
    {:ok, event, _} = Events.add_party(event, "Eu", 1, participant_id: "tok-me")
    {:ok, _} = Events.set_status(event, :payments_only)

    {:ok, view, _html} = live(device_conn(conn, %{event.slug => "tok-me"}), ~p"/")

    assert has_element?(view, card("hm-owe"), "Caloteiro")
  end

  test "the waiting list says Na espera", %{conn: conn} do
    event = create_event(%{"slug" => "hm-wait", "main_size" => "1"})
    {:ok, event, _} = Events.add_party(event, "Outra", 1, participant_id: "tok-other")
    {:ok, _, _} = Events.add_party(event, "Eu", 1, participant_id: "tok-me")

    {:ok, view, _html} = live(device_conn(conn, %{event.slug => "tok-me"}), ~p"/")

    assert has_element?(view, card("hm-wait"), "Na espera")
  end

  test "a hidden rolê I joined on this device shows up", %{conn: conn} do
    event = create_event(%{"slug" => "hm-hidden"})
    {:ok, event, _} = Events.add_party(event, "Eu", 1, participant_id: "tok-me")
    {:ok, _} = Events.set_hidden(event, true)

    {:ok, view, _html} = live(device_conn(conn, %{event.slug => "tok-me"}), ~p"/")

    assert has_element?(view, card("hm-hidden"), "Participando")
  end

  test "a stale device token for a hidden rolê doesn't list it", %{conn: conn} do
    event = create_event(%{"slug" => "hm-stale", "title" => "Segredo"})
    {:ok, event, _} = Events.add_party(event, "Outra", 1, participant_id: "tok-real")
    {:ok, _} = Events.set_hidden(event, true)

    {:ok, view, html} = live(device_conn(conn, %{event.slug => "tok-forged"}), ~p"/")

    refute has_element?(view, card("hm-stale"))
    refute html =~ "Segredo"
  end

  test "a rolê I joined inside an open group shows the group's name", %{conn: conn} do
    {:ok, group} =
      Groups.create(%{
        "name" => "Turma do Vôlei",
        "slug" => "g-#{System.unique_integer([:positive])}"
      })

    event = create_event(%{"slug" => "hm-grouped"}, admin?: true, group_id: group.id)
    {:ok, _, _} = Events.add_party(event, "Eu", 1, participant_id: "tok-me")

    {:ok, view, _html} = live(device_conn(conn, %{event.slug => "tok-me"}), ~p"/")

    assert has_element?(view, card("hm-grouped"), "Turma do Vôlei")
    assert has_element?(view, card("hm-grouped"), "Participando")
  end
end
