defmodule RolezinhoWeb.SplitMethodFormTest do
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Events

  defp admin_conn(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:admin?, true)
  end

  setup %{conn: conn} do
    {:ok, event} =
      Events.create(
        %{
          "title" => "Vôlei",
          "slug" => "smf-#{System.unique_integer([:positive])}",
          "main_size" => "3",
          "wait_size" => "0",
          "price" => "15"
        },
        admin?: true
      )

    {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{event.slug}/edit")
    %{view: view, event: event}
  end

  describe "EventEditLive split method" do
    test "starts on the per-person price with the help button", %{view: view} do
      assert has_element?(view, "#details_split_method option[selected][value=per_person]")
      assert has_element?(view, "#details_price")
      refute has_element?(view, "#details_total")
      assert has_element?(view, "#split-method-help-btn")
      assert has_element?(view, "#split-method-help")
    end

    test "the amount field follows the method", %{view: view} do
      view |> form("#details-form", details: %{split_method: "total_split"}) |> render_change()
      assert has_element?(view, "#details_total")
      refute has_element?(view, "#details_price")

      view |> form("#details-form", details: %{split_method: "settle_up"}) |> render_change()
      refute has_element?(view, "#details_total")
      refute has_element?(view, "#details_price")
    end

    test "saves the method and total", %{view: view, event: event} do
      view |> form("#details-form", details: %{split_method: "total_split"}) |> render_change()

      view
      |> form("#details-form", details: %{split_method: "total_split", total: "300"})
      |> render_submit()

      saved = Events.find(event.slug, visibility: :any)
      assert saved.split_method == :total_split
      assert saved.total_cents == 30_000
    end
  end
end
