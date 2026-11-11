defmodule RolezinhoWeb.WhenWhereTest do
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Event.Meta
  alias Rolezinho.Events

  defp create_event(attrs) do
    defaults = %{
      "title" => "Vôlei",
      "slug" => "wt",
      "description" => "",
      "local" => "",
      "date" => "",
      "time" => "",
      "main_size" => "3",
      "wait_size" => "0"
    }

    {:ok, event} = Events.create(Map.merge(defaults, attrs))
    event
  end

  describe "create form" do
    test "persists local/data/horário at the top of the header in canonical form" do
      event =
        create_event(%{
          "slug" => "com-meta",
          "local" => "Rua Caripunas",
          "date" => "2026-07-15",
          "time" => "19:00",
          "description" => "Valor: 15\nPix: 91984933238"
        })

      assert event.header =~ "Local: Rua Caripunas"
      assert event.header =~ "Data: 15/07/2026"
      assert event.header =~ "Horário: 19:00 (BRT)"
      # Free-form part is preserved
      assert event.header =~ "Valor: 15"
      assert event.header =~ "Pix: 91984933238"

      # And it round-trips through Meta.extract/1
      {meta, _rest} = Meta.extract(event.header)
      assert meta.local == "Rua Caripunas"
      assert meta.date == ~D[2026-07-15]
      assert meta.time == ~T[19:00:00]
    end

    test "omits meta lines that were not provided" do
      event = create_event(%{"slug" => "sem-meta", "description" => "só isso"})

      refute event.header =~ "Local:"
      refute event.header =~ "Data:"
      refute event.header =~ "Horário:"
    end
  end

  describe "event page widget" do
    test "hides meta lines from the description and shows the widget instead", %{conn: conn} do
      event =
        create_event(%{
          "slug" => "widget",
          "local" => "Rua Caripunas",
          "date" => "2026-07-15",
          "time" => "19:00",
          "description" => "Valor: 15"
        })

      {:ok, _view, html} = live(conn, ~p"/r/#{event.slug}")

      # Meta lines rendered by the widget
      assert html =~ "Quando"
      assert html =~ "Onde"
      assert html =~ "Rua Caripunas"
      assert html =~ "15 de julho"

      # Neither raw label appears inside a rendered paragraph
      refute html =~ ~s(<p>Local: Rua Caripunas)
      refute html =~ ~s(<p>Data: 15/07/2026)
      refute html =~ ~s(<p>Hor\u00e1rio: 19:00)

      # But the free-form line stays visible
      assert html =~ "Valor: 15"

      # Calendar buttons show when a date is set
      assert html =~ "Agenda"
      assert html =~ "calendar.google.com"
      assert html =~ ".ics"
    end

    test "hides the widget entirely when nothing is set", %{conn: conn} do
      event = create_event(%{"slug" => "no-widget", "description" => "só descrição"})

      {:ok, _view, html} = live(conn, ~p"/r/#{event.slug}")

      refute html =~ ">Quando<"
      refute html =~ ">Onde<"
      refute html =~ "Agenda"
    end

    test "stacks the widget and the payment details in one column", %{conn: conn} do
      _event =
        create_event(%{
          "slug" => "side-by-side",
          "local" => "Praia",
          "date" => "2026-07-15",
          "time" => "19:00",
          "description" => "Pix: 91985609019"
        })

      {:ok, _view, html} = live(conn, ~p"/r/side-by-side")

      # One column, phone-shaped: a second column would be built for a reader
      # this product does not have.
      refute html =~ "grid sm:grid-cols-2"

      idx_widget = :binary.match(html, "Agenda") |> elem(0)
      idx_key = :binary.match(html, "Chave Pix") |> elem(0)
      idx_desc = :binary.match(html, "Pix: 91985609019") |> elem(0)

      assert idx_widget < idx_desc
      assert idx_key < idx_desc
    end

    test "shows only the parts that are set", %{conn: conn} do
      # Just a location, no date/time
      event =
        create_event(%{
          "slug" => "so-local",
          "local" => "Praia",
          "description" => "algo"
        })

      {:ok, _view, html} = live(conn, ~p"/r/#{event.slug}")

      assert html =~ "Onde"
      assert html =~ "Praia"
      refute html =~ "Quando"
      # No calendar buttons when there is no date
      refute html =~ "Agenda"
    end
  end

  describe "shared/raw text" do
    test "raw endpoint includes meta lines in a readable form", %{conn: conn} do
      _event =
        create_event(%{
          "slug" => "raw-meta",
          "local" => "Praia",
          "date" => "2026-07-15",
          "time" => "19:00"
        })

      conn = get(conn, "/r/raw-meta.txt")
      text = conn.resp_body

      assert text =~ "Local: Praia"
      assert text =~ "Data: 15/07/2026"
      assert text =~ "Horário: 19:00 (BRT)"
    end
  end

  describe "calendar.ics endpoint" do
    test "returns an .ics file with UTC times converted from BRT", %{conn: conn} do
      _event =
        create_event(%{
          "slug" => "calendar",
          "local" => "Praia",
          "date" => "2026-07-15",
          "time" => "19:00"
        })

      conn = get(conn, "/r/calendar/calendar.ics")

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/calendar; charset=utf-8"]

      assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="calendar.ics")
             ]

      body = conn.resp_body
      # 19:00 BRT -> 22:00 UTC
      assert body =~ "DTSTART:20260715T220000Z"
      # Default duration 2h -> 00:00 next day UTC
      assert body =~ "DTEND:20260716T000000Z"
      assert body =~ "SUMMARY:Vôlei"
      assert body =~ "LOCATION:Praia"
    end

    test "returns all-day event when no time is set", %{conn: conn} do
      _event =
        create_event(%{
          "slug" => "allday",
          "date" => "2026-07-15"
        })

      conn = get(conn, "/r/allday/calendar.ics")
      assert conn.status == 200
      body = conn.resp_body
      assert body =~ "DTSTART;VALUE=DATE:20260715"
      assert body =~ "DTEND;VALUE=DATE:20260716"
    end

    test "returns 404 when no date is set", %{conn: conn} do
      _event = create_event(%{"slug" => "nodate", "local" => "X"})
      conn = get(conn, "/r/nodate/calendar.ics")
      assert conn.status == 404
    end
  end

  describe "admin edit form" do
    setup %{conn: conn} do
      event = create_event(%{"slug" => "edit-meta"})

      admin_conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:admin?, true)

      %{conn: admin_conn, event: event}
    end

    test "the merged details form updates local/data/horário and preserves the free-form description",
         %{conn: conn, event: event} do
      # Add some free-form text via the raw context path first — same
      # spot the description lives in on disk today.
      {:ok, _} = Events.save_raw(event, "# Vôlei\n\nValor: 15\n\n1-\n2-\n3-\n")

      {:ok, view, _html} = live(conn, ~p"/admin/r/#{event.slug}/edit")

      # Meta/date/time now live in the single "Detalhes" card alongside
      # title, description, price, pix, password and slug — the whole card
      # saves as one changeset when the user clicks "Salvar".
      current_slug = event.slug

      view
      |> form("#details-form", %{
        "details" => %{
          "title" => event.title,
          "description" => "Valor: 15",
          "local" => "Praia",
          "date" => "2026-07-15",
          "time" => "19:00",
          "price" => "",
          "pix_key" => "",
          "access_code" => "",
          "slug" => current_slug
        }
      })
      |> render_submit()

      reloaded = Events.find(event.slug)
      assert reloaded.header =~ "Local: Praia"
      assert reloaded.header =~ "Data: 15/07/2026"
      assert reloaded.header =~ "Horário: 19:00 (BRT)"
      # Free-form kept
      assert reloaded.header =~ "Valor: 15"
    end
  end
end
