defmodule RolezinhoWeb.PixKeyTypeFormTest do
  @moduledoc """
  The new "Tipo da chave" selector on the create and edit forms.
  Ensures the field is present so the organizer picks the type
  explicitly (never guessed), which was the whole point of adding
  the column.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Accounts
  alias Rolezinho.Events

  defp signed_in(conn, login) do
    {:ok, user} =
      Accounts.find_or_create_by_github(%{
        "github_id" => System.unique_integer([:positive]),
        "github_login" => login
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:current_user_id, user.id)

    {conn, user}
  end

  defp admin_conn(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:admin?, true)
  end

  describe "EventNewLive" do
    test "renders a select for pix_key_type with all five DICT options", %{conn: conn} do
      {conn, _} = signed_in(conn, "pix-form-creator")
      {:ok, view, _html} = live(conn, ~p"/criar")
      view |> element("#new-event-add-payment") |> render_click()

      assert has_element?(view, ~s(select[name="event[pix_key_type]"]))
      # One <option> per DICT type + the empty prompt.
      for type <- Rolezinho.Pix.types() do
        assert has_element?(
                 view,
                 ~s(select[name="event[pix_key_type]"] option[value="#{type}"])
               )
      end
    end
  end

  describe "EventEditLive" do
    test "renders the select preselected to the event's current type", %{conn: conn} do
      {:ok, event} =
        Events.create(
          %{
            "title" => "T",
            "slug" => "pf-#{System.unique_integer([:positive])}",
            "main_size" => "3",
            "wait_size" => "0",
            "price" => "10",
            "pix_key" => "91984933238",
            "pix_key_type" => "phone"
          },
          admin?: true
        )

      {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")

      assert has_element?(view, ~s(select[name="details[pix_key_type]"]))
      # The current type is preselected.
      assert has_element?(
               view,
               ~s(select[name="details[pix_key_type]"] option[value="phone"][selected])
             )
    end
  end
end
