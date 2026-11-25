defmodule RolezinhoWeb.MarkdownXssTest do
  @moduledoc """
  Attribute-injection regression tests (the EEF-CVE-2026-48591 class): a link or image
  URL or title containing a double quote must never close its attribute and inject an
  event handler.

  The rendered markdown reaches the page through `raw(...)`, and writes to an event are
  anonymous, so any visitor can reach this. The protection lives in
  `RolezinhoWeb.Markdown.render/1`.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Events

  defp seed_event(description) do
    {:ok, event} =
      Events.create(%{
        "title" => "Vôlei",
        "slug" => "volei-xss",
        "description" => description,
        "main_size" => "3",
        "wait_size" => "0"
      })

    event
  end

  describe "attribute injection through markdown links" do
    test "a quote in a link URL cannot open a new attribute", %{conn: conn} do
      event = seed_event(~S{End: [aqui](http://x.com/?a=b" onerror="alert(1)) agora})

      {:ok, _view, html} = live(conn, ~p"/r/#{event.slug}")

      refute html =~ ~S{onerror="alert}
    end

    test "a quote in an image URL cannot open a new attribute", %{conn: conn} do
      event = seed_event(~S{End: ![i](http://x.com/a.png" onerror="alert(1)) agora})

      {:ok, _view, html} = live(conn, ~p"/r/#{event.slug}")

      refute html =~ ~S{onerror="alert}
    end

    test "a quote in a link title cannot open a new attribute", %{conn: conn} do
      event = seed_event(~S{End: [aqui](http://x.com/ "t" onmouseover="alert(1)) agora})

      {:ok, _view, html} = live(conn, ~p"/r/#{event.slug}")

      refute html =~ ~S{onmouseover="alert}
    end

    test "legitimate formatting still renders", %{conn: conn} do
      # WhatsApp markup: *bold* and _italic_, which is what the field accepts.
      event = seed_event("End: *Praia* do _Farol_\nHorário: 19h")

      {:ok, _view, html} = live(conn, ~p"/r/#{event.slug}")

      assert html =~ "<strong>Praia</strong>"
      assert html =~ "<em>Farol</em>"
    end
  end
end
