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

  test "grouped rolês come first, by group name, then the rest by date", %{conn: conn} do
    {:ok, zeta} =
      Groups.create(%{"name" => "Zeta", "slug" => "g-zeta-#{System.unique_integer([:positive])}"})

    {:ok, alfa} =
      Groups.create(%{"name" => "alfa", "slug" => "g-alfa-#{System.unique_integer([:positive])}"})

    loose = create_event(%{"slug" => "hm-loose", "date" => "2026-11-01", "time" => "10:00"})

    in_zeta =
      create_event(%{"slug" => "hm-zeta", "date" => "2026-11-02"},
        admin?: true,
        group_id: zeta.id
      )

    in_alfa =
      create_event(%{"slug" => "hm-alfa", "date" => "2026-11-03"},
        admin?: true,
        group_id: alfa.id
      )

    tokens =
      for event <- [loose, in_zeta, in_alfa], into: %{} do
        {:ok, _, _} = Events.add_party(event, "Eu", 1, participant_id: "tok-#{event.slug}")
        {event.slug, "tok-#{event.slug}"}
      end

    {:ok, view, _html} = live(device_conn(conn, tokens), ~p"/")

    slugs =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("li > a[href^='/r/hm-']")
      |> LazyHTML.attribute("href")

    assert slugs == ["/r/hm-alfa", "/r/hm-zeta", "/r/hm-loose"]
  end

  test "a group holding a rolê I'm on gets the blue tile; others keep theirs", %{conn: conn} do
    {:ok, mine} =
      Groups.create(%{
        "name" => "Minha Turma",
        "slug" => "g-mine-#{System.unique_integer([:positive])}"
      })

    {:ok, other} =
      Groups.create(%{
        "name" => "Outra Turma",
        "slug" => "g-other-#{System.unique_integer([:positive])}"
      })

    event = create_event(%{"slug" => "hm-in-mine"}, admin?: true, group_id: mine.id)
    {:ok, _, _} = Events.add_party(event, "Eu", 1, participant_id: "tok-me")
    create_event(%{"slug" => "hm-in-other"}, admin?: true, group_id: other.id)

    {:ok, view, _html} = live(device_conn(conn, %{event.slug => "tok-me"}), ~p"/")

    assert has_element?(view, ~s(#group-list a[href="/g/#{mine.slug}"] .bg-info))
    refute has_element?(view, ~s(#group-list a[href="/g/#{other.slug}"] .bg-info))
    assert has_element?(view, ~s(#group-list a[href="/g/#{other.slug}"] .bg-accent))
  end

  test "anonymous visitors get the sign-in prompt; signed-in users don't", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-sign-in-prompt")
    assert has_element?(view, ~s(#home-sign-in-btn[href^="/entrar"]))

    {:ok, user} =
      Rolezinho.Accounts.find_or_create_by_github(%{
        "github_id" => System.unique_integer([:positive]),
        "github_login" => "prompt-user"
      })

    signed_in =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:current_user_id, user.id)

    {:ok, view, _html} = live(signed_in, ~p"/")
    refute has_element?(view, "#home-sign-in-prompt")
  end
end
