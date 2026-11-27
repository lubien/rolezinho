defmodule Rolezinho.MultiShareTest do
  use ExUnit.Case, async: true

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.MultiShare

  defp event(attrs) do
    struct!(
      %Event{slug: "role", title: "Rolê", status: :active, main_capacity: 8, main_list: []},
      attrs
    )
  end

  defp attendees(specs),
    do: Enum.map(specs, fn {name, paid} -> %Attendee{name: name, paid: paid} end)

  defp url(%Event{slug: slug}), do: "https://rolezinho.test/r/" <> slug

  test "renders the header and one line per event, in order" do
    events = [
      event(
        slug: "volei",
        title: "Vôlei",
        main_capacity: 18,
        main_list: attendees(for i <- 1..12, do: {"P#{i}", false}) ++ [%Attendee{name: ""}]
      ),
      event(
        slug: "churras",
        title: "Churras",
        status: :payments_only,
        main_capacity: 20,
        main_list: attendees([{"Ana", true}, {"Bia", false}, {"", false}])
      ),
      event(
        slug: "cowork",
        title: "Coworking",
        status: :maybe,
        main_list: attendees([{"Caio", false}, {"Duda", false}, {"Edu", false}])
      )
    ]

    assert MultiShare.to_text(events, &url/1) == """
           Rolezinhos ativos

           * Vôlei: 12/18. https://rolezinho.test/r/volei
           * Churras: Apenas pagamentos 01/02. https://rolezinho.test/r/churras
           * Coworking: Averiguando Resenha 03/08. https://rolezinho.test/r/cowork
           """
  end

  test "does not pad counts that already have two or more digits" do
    main_list = attendees(for i <- 1..100, do: {"P#{i}", false})
    text = MultiShare.to_text([event(main_capacity: 120, main_list: main_list)], &url/1)

    assert text =~ "* Rolê: 100/120."
  end

  test "an empty selection renders only the header" do
    assert MultiShare.to_text([], &url/1) == "Rolezinhos ativos\n\n"
  end

  describe ":include_password" do
    setup do
      %{
        events: [
          event(slug: "locked", title: "Trancado", password: "fofoca"),
          event(slug: "open", title: "Aberto")
        ]
      }
    end

    test "appends the password only to protected events", %{events: events} do
      text = MultiShare.to_text(events, &url/1, include_password: true)

      assert text =~ "* Trancado: 00/08. https://rolezinho.test/r/locked Senha: fofoca\n"
      assert text =~ "* Aberto: 00/08. https://rolezinho.test/r/open\n"
    end

    test "leaves passwords out by default", %{events: events} do
      refute MultiShare.to_text(events, &url/1) =~ "fofoca"
    end
  end

  describe "to_image_rows/1" do
    test "builds one row per event with title, place, time and count" do
      [row] =
        MultiShare.to_image_rows([
          event(
            title: "  Vôlei ",
            local: "Quadra do Ibirapuera",
            starts_at: ~U[2026-12-04 22:00:00Z],
            main_capacity: 18,
            main_list: attendees([{"Ana", false}, {"Bia", true}, {" ", false}])
          )
        ])

      assert row == %{
               title: "Vôlei",
               place: "Quadra do Ibirapuera",
               when: "Sex, 04/12 · 19h",
               count: 2,
               total: 18,
               tag: nil
             }
    end

    test "shows minutes only when the start is not on the hour" do
      [row] = MultiShare.to_image_rows([event(starts_at: ~U[2026-12-13 00:30:00Z])])

      assert row.when == "Sáb, 12/12 · 21h30"
    end

    test "leaves time and place out when unset" do
      [row] = MultiShare.to_image_rows([event(local: "  ")])

      assert row.when == nil
      assert row.place == nil
    end

    test "payments-only counts paid over filled and carries a tag" do
      [row] =
        MultiShare.to_image_rows([
          event(
            status: :payments_only,
            main_capacity: 20,
            main_list: attendees([{"Ana", true}, {"Bia", false}, {"", false}])
          )
        ])

      assert {row.count, row.total, row.tag} == {1, 2, "Apenas pagamentos"}
    end

    test "the tentative status carries its label as the tag" do
      [row] = MultiShare.to_image_rows([event(status: :maybe)])

      assert row.tag == "Averiguando Resenha"
    end

    test "a password-protected event keeps its place and password out" do
      [row] =
        MultiShare.to_image_rows([
          event(password: "fofoca", local: "Casa da Ana", title: "Trancado")
        ])

      assert row.place == nil
      refute inspect(row) =~ "fofoca"
    end
  end
end
