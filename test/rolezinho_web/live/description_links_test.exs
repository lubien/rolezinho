defmodule RolezinhoWeb.DescriptionLinksTest do
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Events

  test "a link in the description is clickable and opens safely", %{conn: conn} do
    {:ok, event} =
      Events.create(
        %{
          "title" => "Pelada",
          "slug" => "links-#{System.unique_integer([:positive])}",
          "main_size" => "3",
          "wait_size" => "0",
          "description" => "Mapa: https://maps.example.com/quadra\n<script>alert(1)</script>"
        },
        admin?: true
      )

    {:ok, view, html} = live(conn, ~p"/r/#{event.slug}")

    assert has_element?(
             view,
             ~s(#organizer-note a[href="https://maps.example.com/quadra"][target="_blank"][rel="noopener noreferrer nofollow"])
           )

    refute html =~ "<script>alert(1)</script>"
  end
end
