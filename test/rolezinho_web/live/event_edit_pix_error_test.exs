defmodule RolezinhoWeb.EventEditPixErrorTest do
  @moduledoc """
  Legacy events (pix_key set but pix_key_type nil) hitting the edit form
  used to surface `{:error, %{pix_key_type: [...]}}` as an opaque flash
  ("Não deu pra salvar: %{pix_key_type: ...}"). The form is now expected
  to:

    * render a helpful flash ("Escolha o tipo da chave Pix..."),
    * highlight the pix_key_type select with the inline error text,
    * NOT dump the raw error map.

  This locks the fix in against regressions when the error-shape ever
  moves again.
  """
  use RolezinhoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Rolezinho.Event
  alias Rolezinho.Repo

  defp admin_conn(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:admin?, true)
  end

  # Build an event with a pix_key but *without* pix_key_type — the
  # legacy shape events had before the split. Going through `Events.create`
  # would fail the pair validation now, so we insert straight through Repo.
  defp legacy_event(slug) do
    {:ok, event} =
      %Event{
        slug: slug,
        title: "Legacy",
        status: :active,
        hidden: false,
        header: "",
        footer: "",
        main_capacity: 3,
        wait_enabled: false,
        wait_intro: "Lista de reserva",
        main_list: [
          %{name: "", paid: false},
          %{name: "", paid: false},
          %{name: "", paid: false}
        ],
        wait_list: [],
        form_fields: [],
        pix_key: "91984933238",
        pix_key_type: nil,
        organizer_token: "tok-#{System.unique_integer([:positive])}"
      }
      |> Repo.insert()

    event
  end

  test "submitting the details form on a legacy event surfaces a helpful flash + inline error",
       %{conn: conn} do
    slug = "legacy-#{System.unique_integer([:positive])}"
    legacy_event(slug)

    {:ok, view, _html} = live(admin_conn(conn), ~p"/admin/r/#{slug}/edit")

    # Submit the details form as-is. `pix_key_type` is empty because the
    # legacy event had none, and the browser sends the prompt option's
    # empty value.
    html =
      view
      |> form("#details-form", %{
        "details" => %{
          "title" => "Legacy",
          "description" => "",
          "category" => "",
          "local" => "",
          "date" => "",
          "time" => "",
          "price" => "",
          "pix_key" => "91984933238",
          "pix_key_type" => "",
          "access_code" => "",
          "slug" => slug
        }
      })
      |> render_submit()

    # Helpful, product-language flash (not an inspect() dump).
    assert html =~ "Escolha o tipo da chave Pix"
    refute html =~ "%{pix_key_type:"

    # And the select is highlighted inline with the field-level error.
    assert html =~ "escolha o tipo da chave"
  end
end
