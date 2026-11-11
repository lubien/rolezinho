defmodule RolezinhoWeb.PasswordManagerOptOutTest do
  @moduledoc """
  Event and group passwords are shared codes, not logins. Password managers
  key on "password" in an input's name or id, so none of the four forms may
  render one — and the password must still save under the renamed field.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Accounts
  alias Rolezinho.Events
  alias Rolezinho.Groups

  defp admin(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:admin?, true)
  end

  defp password_like_inputs(html, form_selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{form_selector} input")
    |> Enum.flat_map(fn input ->
      LazyHTML.attribute(input, "name") ++ LazyHTML.attribute(input, "id")
    end)
    |> Enum.filter(&String.contains?(String.downcase(&1), "password"))
  end

  defp event(overrides \\ %{}) do
    {:ok, event} =
      Events.create(
        Map.merge(
          %{
            "title" => "Rolê",
            "slug" => "pm-#{System.unique_integer([:positive])}",
            "main_size" => "2",
            "wait_size" => "0"
          },
          overrides
        ),
        admin?: true
      )

    event
  end

  describe "no input is named or id'd like a password" do
    test "event create form", %{conn: conn} do
      {:ok, _view, html} = live(admin(conn), ~p"/criar")
      assert password_like_inputs(html, "#new-event-form") == []
    end

    test "event edit form", %{conn: conn} do
      event = event()
      {:ok, _view, html} = live(admin(conn), ~p"/admin/r/#{event.slug}/edit")
      assert password_like_inputs(html, "#details-form") == []
    end

    test "group create form", %{conn: conn} do
      {:ok, _view, html} = live(admin(conn), ~p"/g/criar")
      assert password_like_inputs(html, "#new-group-form") == []
    end

    test "group edit form", %{conn: conn} do
      {:ok, group} =
        Groups.create(%{"name" => "Turma", "slug" => "pm-g-#{System.unique_integer([:positive])}"})

      {:ok, _view, html} = live(admin(conn), ~p"/admin/g/#{group.slug}/edit")
      assert password_like_inputs(html, "#group-password-form") == []
    end
  end

  describe "the password still saves" do
    test "creating an event", %{conn: conn} do
      slug = "pm-new-#{System.unique_integer([:positive])}"

      post(admin(conn), ~p"/criar", %{
        "event" => %{
          "title" => "Rolê",
          "slug" => slug,
          "main_size" => "2",
          "wait_size" => "0",
          "access_code" => "fofoca"
        }
      })

      assert Events.find(slug, visibility: :any).password == "fofoca"
    end

    test "editing an event", %{conn: conn} do
      event = event(%{"local" => "Quadra", "date" => "2026-11-20", "time" => "19:00"})
      {:ok, view, _html} = live(admin(conn), ~p"/admin/r/#{event.slug}/edit")

      view
      |> form("#details-form", %{"details" => %{"access_code" => "nova"}})
      |> render_submit()

      assert Events.find(event.slug, visibility: :any).password == "nova"
    end

    test "creating a group", %{conn: conn} do
      {:ok, user} =
        Accounts.find_or_create_by_github(%{
          "github_id" => System.unique_integer([:positive]),
          "github_login" => "pm-group"
        })

      slug = "pm-gnew-#{System.unique_integer([:positive])}"

      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:current_user_id, user.id)
      |> post(~p"/g/criar", %{
        "group" => %{"name" => "Turma", "slug" => slug, "access_code" => "segredo"}
      })

      assert Groups.find(slug).password == "segredo"
    end
  end
end
