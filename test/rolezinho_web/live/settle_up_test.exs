defmodule RolezinhoWeb.SettleUpTest do
  @moduledoc """
  The "Dividir no final" card on `/r/:slug`: who may fill in what they spent,
  and that the server re-checks it.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Events

  defp create_event(overrides \\ %{}) do
    defaults = %{
      "title" => "Churras",
      "slug" => "settle-#{System.unique_integer([:positive])}",
      "main_size" => "4",
      "wait_size" => "0",
      "split_method" => "settle_up"
    }

    {:ok, event} = Events.create(Map.merge(defaults, overrides), admin?: true)
    {:ok, event, _} = Events.add_party(event, "Ana", 1, participant_id: "tok-ana")
    {:ok, event, _} = Events.add_party(event, "Bruno", 1, participant_id: "tok-bruno")
    event
  end

  defp participant_conn(conn, token, slug) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:participants, %{slug => token})
  end

  defp admin_conn(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:admin?, true)
  end

  test "a participant can fill in only their own row", %{conn: conn} do
    event = create_event()
    {:ok, view, _html} = live(participant_conn(conn, "tok-ana", event.slug), ~p"/r/#{event.slug}")

    assert has_element?(view, "#settlement")
    assert has_element?(view, "#contribution-form-1")
    refute has_element?(view, "#contribution-form-2")

    view |> form("#contribution-form-1", %{amount: "200"}) |> render_submit()

    assert Events.find(event.slug, visibility: :any).main_list
           |> hd()
           |> Map.get(:contributed_cents) ==
             20_000

    assert has_element?(view, "#settlement-sender-2", "Bruno")
  end

  test "a forged write to someone else's row is ignored", %{conn: conn} do
    event = create_event()
    {:ok, view, _html} = live(participant_conn(conn, "tok-ana", event.slug), ~p"/r/#{event.slug}")

    render_hook(view, "set_contribution", %{"index" => "2", "amount" => "500"})

    assert Enum.at(Events.find(event.slug, visibility: :any).main_list, 1).contributed_cents == 0
  end

  test "an invalid amount is not saved", %{conn: conn} do
    event = create_event()
    {:ok, view, _html} = live(participant_conn(conn, "tok-ana", event.slug), ~p"/r/#{event.slug}")

    render_hook(view, "set_contribution", %{"index" => "1", "amount" => "999999999"})

    assert hd(Events.find(event.slug, visibility: :any).main_list).contributed_cents == 0
  end

  test "the admin can fill in every row", %{conn: conn} do
    event = create_event()
    {:ok, view, _html} = live(admin_conn(conn), ~p"/r/#{event.slug}")

    assert has_element?(view, "#contribution-form-1")
    assert has_element?(view, "#contribution-form-2")
  end

  test "other methods have no card and ignore the event", %{conn: conn} do
    event = create_event(%{"split_method" => "per_person", "price" => "15"})
    {:ok, view, _html} = live(participant_conn(conn, "tok-ana", event.slug), ~p"/r/#{event.slug}")

    refute has_element?(view, "#settlement")

    render_hook(view, "set_contribution", %{"index" => "1", "amount" => "200"})

    assert hd(Events.find(event.slug, visibility: :any).main_list).contributed_cents == 0
  end

  test "a locked password-protected event does not render the plan", %{conn: conn} do
    event = create_event(%{"password" => "fofoca"})
    {:ok, view, html} = live(conn, ~p"/r/#{event.slug}")

    refute has_element?(view, "#settlement")
    refute html =~ "Plano de pagamento"
  end
end
