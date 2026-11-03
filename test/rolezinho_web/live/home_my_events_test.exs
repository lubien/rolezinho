defmodule RolezinhoWeb.HomeMyEventsTest do
  @moduledoc """
  Signed-in callers see their own rolezinhos on the home page in addition
  to the public listing:

    * ones they created (`created_by_user_id`),
    * ones they joined (either the main or the wait list).

  Hidden and grouped rolezinhos count too — they are "mine" first and
  home-page-eligible second. `:done` ones don't, since the home is about
  what is next.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Accounts
  alias Rolezinho.Events
  alias Rolezinho.Groups

  defp create_user(login) do
    {:ok, user} =
      Accounts.find_or_create_by_github(%{
        "github_id" => System.unique_integer([:positive]),
        "github_login" => login
      })

    user
  end

  defp signed_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:current_user_id, user.id)
  end

  defp create_event(overrides, opts \\ [admin?: true]) do
    defaults = %{
      "title" => "Rolê",
      "slug" => "e-#{System.unique_integer([:positive])}",
      "main_size" => "3",
      "wait_size" => "0"
    }

    {:ok, event} = Events.create(Map.merge(defaults, overrides), opts)
    event
  end

  test "shows an event the signed-in user created, even when hidden", %{conn: conn} do
    user = create_user("owner-1")

    mine =
      create_event(%{"title" => "Meu rolê", "slug" => "mine-1"},
        admin?: false,
        created_by_user_id: user.id
      )

    {:ok, _} = Events.set_hidden(mine, true)

    conn = signed_in(conn, user)
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Meu rolê"
  end

  test "shows an event the signed-in user joined (main list)", %{conn: conn} do
    user = create_user("joiner-1")
    event = create_event(%{"title" => "Fui nesse", "slug" => "joined-1"})

    # Passing `user_id:` mirrors what the JoinController does for a
    # signed-in visitor.
    {:ok, _} =
      Events.add_to_main(event, "Alice",
        participant_id: "tok",
        user_id: user.id
      )

    conn = signed_in(conn, user)
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Fui nesse"
  end

  test "shows an event the signed-in user joined on the wait list", %{conn: conn} do
    user = create_user("waiter-1")

    event =
      create_event(%{
        "title" => "Estou na fila",
        "slug" => "waited-1",
        "main_size" => "1",
        "wait_size" => "3"
      })

    {:ok, _} =
      Events.add_to_wait(event, "Alice",
        participant_id: "tok",
        user_id: user.id
      )

    conn = signed_in(conn, user)
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Estou na fila"
  end

  test "does NOT show events the user is not tied to", %{conn: conn} do
    user = create_user("stranger-viewer")
    other = create_user("someone-else")

    _theirs =
      create_event(%{"title" => "Não é meu", "slug" => "not-mine-1"},
        admin?: false,
        created_by_user_id: other.id
      )

    # Explicitly hide it so it doesn't sneak in via the public listing.
    theirs = Events.find("not-mine-1")
    {:ok, _} = Events.set_hidden(theirs, true)

    conn = signed_in(conn, user)
    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "Não é meu"
  end

  test "does NOT show a :done rolê the user owns — the home is about what is next",
       %{conn: conn} do
    user = create_user("archived-owner")

    _mine =
      create_event(%{"title" => "Arquivado", "slug" => "done-1"},
        admin?: false,
        created_by_user_id: user.id
      )

    mine = Events.find("done-1")
    {:ok, _} = Events.set_status(mine, :done)

    conn = signed_in(conn, user)
    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "Arquivado"
  end

  test "anonymous callers still see only the public listing", %{conn: conn} do
    user = create_user("ghost-owner")

    _mine =
      create_event(%{"title" => "Escondido do estranho", "slug" => "anon-check-1"},
        admin?: false,
        created_by_user_id: user.id
      )

    mine = Events.find("anon-check-1")
    {:ok, _} = Events.set_hidden(mine, true)

    # Anonymous conn.
    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "Escondido do estranho"
  end

  test "a grouped rolê the user owns does NOT surface on the home", %{conn: conn} do
    # Invariant: an event that belongs to a group lives on that group's
    # page, not on `/`. Applies to hidden and visible events, and to
    # owned and joined rows alike — the group page is the one entry
    # point (password gating on a group relies on it). The user reaches
    # the event by opening their group.
    user = create_user("grouped-owner")

    {:ok, group} =
      Groups.create(%{
        "name" => "Meu Grupo",
        "slug" => "g-#{System.unique_integer([:positive])}"
      })

    _mine =
      create_event(%{"title" => "Dentro do grupo", "slug" => "in-group-1"},
        admin?: false,
        created_by_user_id: user.id,
        group_id: group.id
      )

    conn = signed_in(conn, user)
    {:ok, view, _html} = live(conn, ~p"/")

    # No card links to it. The title alone is not the check: the
    # multi-share sheet lists every owned rolê, grouped ones included.
    refute has_element?(view, ~s(a[href="/r/in-group-1"]))
  end

  test "a hidden grouped rolê the user owns also does NOT surface on the home",
       %{conn: conn} do
    # Specific case the user hit in prod: hidden + grouped + owned by me
    # was leaking onto `/`. Both filters (hidden hides on public shelf;
    # grouped hides on private shelf) must combine so the event only
    # appears on its group's page.
    user = create_user("grouped-hidden-owner")

    {:ok, group} =
      Groups.create(%{
        "name" => "Meu Grupo",
        "slug" => "gh-#{System.unique_integer([:positive])}"
      })

    {:ok, mine} =
      Events.create(
        %{
          "title" => "Escondido no grupo",
          "slug" => "hidden-in-group-1",
          "main_size" => "3",
          "wait_size" => "0"
        },
        admin?: false,
        created_by_user_id: user.id,
        group_id: group.id
      )

    {:ok, _} = Events.set_hidden(mine, true)

    conn = signed_in(conn, user)
    {:ok, view, _html} = live(conn, ~p"/")

    # No card links to it. The title alone is not the check: the
    # multi-share sheet lists every owned rolê, grouped ones included.
    refute has_element?(view, ~s(a[href="/r/hidden-in-group-1"]))
  end
end
