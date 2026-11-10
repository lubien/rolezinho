defmodule RolezinhoWeb.OrganizerNoteTest do
  @moduledoc """
  The organizer's description on `/r/:slug` keeps the shape it was typed in:
  single line breaks stay line breaks, and a blank line starts a new,
  visibly separated paragraph — the same breaks the shared text keeps.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Events

  setup %{conn: conn} do
    {:ok, event} =
      Events.create(
        %{
          "title" => "Pelada",
          "slug" => "note-#{System.unique_integer([:positive])}",
          "main_size" => "3",
          "wait_size" => "0",
          "description" => "Bora jogar!\r\nTraz água\r\n\r\nQualquer coisa me chama"
        },
        admin?: true
      )

    {:ok, view, _html} = live(conn, ~p"/r/#{event.slug}")
    %{view: view}
  end

  test "a blank line becomes a separate paragraph", %{view: view} do
    assert has_element?(view, "#organizer-note > p", "Bora jogar!")
    assert has_element?(view, "#organizer-note > p", "Qualquer coisa me chama")
    refute has_element?(view, "#organizer-note > p", "Traz água Qualquer")
  end

  test "a single line break stays a line break", %{view: view} do
    assert has_element?(view, "#organizer-note > p br")
  end

  test "paragraphs get vertical spacing without the typography plugin", %{view: view} do
    [class] =
      view
      |> element("#organizer-note")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("class")

    assert class =~ "space-y-3"
    refute class =~ "prose"
  end
end
