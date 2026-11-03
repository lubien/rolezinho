defmodule RolezinhoWeb.HomeMultiShareTest do
  @moduledoc """
  The home page "multi share" sheet: a signed-in owner picks some of their
  non-done rolezinhos and gets one message to paste into a group chat.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Accounts
  alias Rolezinho.Events

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

  defp create_event(user, overrides) do
    defaults = %{
      "title" => "Rolê",
      "slug" => "e-#{System.unique_integer([:positive])}",
      "main_size" => "3",
      "wait_size" => "0"
    }

    {:ok, event} =
      Events.create(Map.merge(defaults, overrides),
        admin?: false,
        created_by_user_id: user && user.id
      )

    event
  end

  defp share_text(view) do
    view
    |> element("#multi-share-copy-btn")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-text")
    |> List.first()
  end

  test "the share button is absent for anonymous visitors", %{conn: conn} do
    create_event(nil, %{"slug" => "ms-public"})

    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#multi-share-btn")
    refute has_element?(view, "#multi-share-sheet")
  end

  test "the share button is absent for a user who owns nothing shareable", %{conn: conn} do
    user = create_user("ms-nobody")

    {:ok, view, _html} = live(signed_in(conn, user), ~p"/")

    refute has_element?(view, "#multi-share-btn")
  end

  test "lists the owner's events, all selected, and builds the message", %{conn: conn} do
    owner = create_user("ms-owner-2")
    volei = create_event(owner, %{"title" => "Vôlei", "slug" => "ms-volei"})
    churras = create_event(owner, %{"title" => "Churras", "slug" => "ms-churras"})

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/")

    assert has_element?(view, "#multi-share-btn")
    assert has_element?(view, "#multi-share-event-#{volei.id}[checked]")
    assert has_element?(view, "#multi-share-event-#{churras.id}[checked]")

    text = share_text(view)
    assert text =~ "Rolezinhos ativos"
    assert text =~ "* Vôlei: 00/03. "
    assert text =~ "/r/ms-volei"
    assert text =~ "* Churras: 00/03. "
  end

  test "unchecking an event drops it from the message", %{conn: conn} do
    owner = create_user("ms-owner-3")
    volei = create_event(owner, %{"title" => "Vôlei", "slug" => "ms-volei-3"})
    create_event(owner, %{"title" => "Churras", "slug" => "ms-churras-3"})

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/")

    view |> element("#multi-share-event-#{volei.id}") |> render_click()

    refute has_element?(view, "#multi-share-event-#{volei.id}[checked]")
    refute share_text(view) =~ "Vôlei"
    assert share_text(view) =~ "Churras"
  end

  test "a forged id for someone else's event is ignored", %{conn: conn} do
    owner = create_user("ms-owner-4")
    other = create_user("ms-other-4")
    create_event(owner, %{"title" => "Meu", "slug" => "ms-mine-4"})
    theirs = create_event(other, %{"title" => "Alheio", "slug" => "ms-theirs-4"})

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/")

    render_hook(view, "multi_share_toggle", %{"id" => Integer.to_string(theirs.id)})
    render_hook(view, "multi_share_toggle", %{"id" => "not-a-number"})

    refute share_text(view) =~ "Alheio"
  end

  test "the password toggle adds passwords only when checked", %{conn: conn} do
    owner = create_user("ms-owner-5")
    locked = create_event(owner, %{"title" => "Trancado", "slug" => "ms-locked"})
    {:ok, _} = Events.update_password(locked, "fofoca")

    {:ok, view, html} = live(signed_in(conn, owner), ~p"/")

    refute html =~ "fofoca"

    view |> element("#multi-share-password-toggle") |> render_click()
    assert share_text(view) =~ "/r/ms-locked Senha: fofoca"

    view |> element("#multi-share-password-toggle") |> render_click()
    refute share_text(view) =~ "fofoca"
  end

  test "the password toggle is absent when no owned event has a password", %{conn: conn} do
    owner = create_user("ms-owner-6")
    create_event(owner, %{"slug" => "ms-open-6"})

    {:ok, view, _html} = live(signed_in(conn, owner), ~p"/")

    refute has_element?(view, "#multi-share-password-toggle")
  end
end
