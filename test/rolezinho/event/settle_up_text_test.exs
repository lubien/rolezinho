defmodule Rolezinho.Event.SettleUpTextTest do
  use ExUnit.Case, async: true

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.Cash

  defp event do
    people =
      [{"Ana", 20_000, false}, {"Bruno", 12_000, false}, {"Carla", 0, true}] ++
        for(n <- ~w(Davi Edu Fê Gabi Hugo Iris), do: {n, 0, false}) ++ [{"João", 0, true}]

    %Event{
      slug: "churras",
      title: "Churras",
      status: :active,
      split_method: :settle_up,
      main_capacity: 10,
      main_list:
        for(
          {name, cents, paid} <- people,
          do: %Attendee{name: name, contributed_cents: cents, paid: paid}
        ),
      wait_list: []
    }
  end

  test "the shared text explains the plan and marks who already sent" do
    text = Event.to_text(event(), "https://rolezinho.test/r/churras")

    assert text =~ "Dividir no final · Total R$ 320 · R$ 32 por pessoa"
    assert text =~ "Plano de pagamento\nCarla manda R$ 32 para Ana ✅\nDavi manda R$ 32 para Ana\n"
    assert text =~ "Hugo manda R$ 8 para Ana e R$ 24 para Bruno\n"
    assert text =~ "João manda R$ 32 para Bruno ✅"
    assert text =~ "1- Ana (pagou R$ 200)\n2- Bruno (pagou R$ 120)\n3- Carla ✅"
  end

  test "the plan is left out with the names" do
    text = Event.to_text(event(), nil, hide_names: true)

    refute text =~ "Plano de pagamento"
    refute text =~ "Ana"
    refute text =~ "pagou"
  end

  test "the plan is left out with the description" do
    refute Event.to_text(event(), nil, hide_description: true) =~ "Plano de pagamento"
  end

  test "Cash counts only the people who still have to send money" do
    summary = Cash.summary(event())

    assert summary.per_person_cents == nil
    assert summary.debtors == ~w(Davi Edu Fê Gabi Hugo Iris)
    assert summary.missing_cents == 6 * 3200
    assert summary.paid_count == 2
    assert summary.total_count == 8
  end

  test "the reminder does not point at the organizer's Pix" do
    reminder = Cash.reminder_text(%{event() | pix_key: "91984933238"})

    refute reminder =~ "91984933238"
  end

  test "lists each receiver's Pix key once, after the plan" do
    [ana, bruno | rest] = event().main_list
    event = %{event() | main_list: [%{ana | pix_key: "ana@exemplo.com"}, bruno | rest]}

    text = Event.to_text(event)

    assert text =~ "João manda R$ 32 para Bruno ✅\n\nPix de quem recebe\nAna: ana@exemplo.com\n"
    refute text =~ "Bruno: "
  end

  test "no Pix block when no receiver has a key" do
    refute Event.to_text(event()) =~ "Pix de quem recebe"
  end
end
