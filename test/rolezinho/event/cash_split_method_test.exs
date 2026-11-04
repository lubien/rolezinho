defmodule Rolezinho.Event.CashSplitMethodTest do
  use ExUnit.Case, async: true

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.Cash

  defp event(attrs) do
    struct!(
      %Event{slug: "role", title: "Rolê", status: :active, main_capacity: 18, main_list: []},
      attrs
    )
  end

  defp people(paid, unpaid) do
    Enum.map(1..paid//1, &%Attendee{name: "Pago #{&1}", paid: true}) ++
      Enum.map(1..unpaid//1, &%Attendee{name: "Devendo #{&1}", paid: false})
  end

  describe "per_person_cents/1" do
    test ":per_person and :per_seat use the price as typed" do
      assert Cash.per_person_cents(event(split_method: :per_person, price_cents: 1500)) == 1500
      assert Cash.per_person_cents(event(split_method: :per_seat, price_cents: 1500)) == 1500
    end

    test ":total_split divides the total by who is on the list" do
      event = event(split_method: :total_split, total_cents: 30_000, main_list: people(0, 12))

      assert Cash.per_person_cents(event) == 2500
    end

    test ":total_split rounds up to the cent so the organizer is never short" do
      event = event(split_method: :total_split, total_cents: 30_000, main_list: people(0, 13))

      assert Cash.per_person_cents(event) == 2308
    end

    test ":total_split has no per-person amount while the list is empty" do
      assert Cash.per_person_cents(event(split_method: :total_split, total_cents: 30_000)) == nil
    end

    test ":settle_up has no fixed price" do
      assert Cash.per_person_cents(event(split_method: :settle_up, price_cents: 1500)) == nil
    end

    test "no amount means nil" do
      assert Cash.per_person_cents(event(split_method: :per_person, price_cents: nil)) == nil
      assert Cash.per_person_cents(event(split_method: :per_person, price_cents: 0)) == nil
    end
  end

  describe "summary/1" do
    test ":per_seat counts empty seats as missing, apart from people who owe" do
      event = event(split_method: :per_seat, price_cents: 1500, main_list: people(8, 4))
      summary = Cash.summary(event)

      assert summary.empty_seats == 6
      assert summary.empty_seats_cents == 9000
      assert summary.missing_cents == 4 * 1500 + 9000
      assert summary.expected_cents == 18 * 1500
      assert length(summary.debtors) == 4
    end

    test ":per_person ignores empty seats" do
      summary =
        Cash.summary(event(split_method: :per_person, price_cents: 1500, main_list: people(8, 4)))

      assert summary.empty_seats == 0
      assert summary.missing_cents == 4 * 1500
    end

    test ":total_split charges each person their share" do
      event = event(split_method: :total_split, total_cents: 30_000, main_list: people(7, 5))
      summary = Cash.summary(event)

      assert summary.per_person_cents == 2500
      assert summary.missing_cents == 5 * 2500
    end
  end

  describe "outstanding?/1" do
    test "a :per_seat event where everyone paid but seats are empty is still outstanding" do
      assert Cash.outstanding?(
               event(split_method: :per_seat, price_cents: 1500, main_list: people(12, 0))
             )
    end
  end

  describe "amount_line_text/1" do
    test "describes the amount for each method" do
      assert Cash.amount_line_text(event(split_method: :per_person, price_cents: 1500)) ==
               "R$ 15 por pessoa"

      assert Cash.amount_line_text(event(split_method: :per_seat, price_cents: 1550)) ==
               "R$ 15,50 por pessoa"

      assert Cash.amount_line_text(
               event(split_method: :total_split, total_cents: 30_000, main_list: people(0, 12))
             ) == "Total R$ 300 · R$ 25 por pessoa"

      assert Cash.amount_line_text(event(split_method: :total_split, total_cents: 30_000)) ==
               "Total R$ 300"

      assert Cash.amount_line_text(event(split_method: :per_person, price_cents: nil)) == nil
    end
  end
end
