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
end
