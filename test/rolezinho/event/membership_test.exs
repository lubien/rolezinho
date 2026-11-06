defmodule Rolezinho.Event.MembershipTest do
  use ExUnit.Case, async: true

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.Membership

  defp event(attrs) do
    struct!(
      %Event{
        status: :active,
        split_method: :per_person,
        price_cents: 1500,
        main_list: [],
        wait_list: []
      },
      attrs
    )
  end

  defp mine(attrs \\ []), do: struct!(%Attendee{name: "Eu", participant_id: "tok"}, attrs)
  defp other(attrs \\ []), do: struct!(%Attendee{name: "Outra", participant_id: "x"}, attrs)

  test "nil when the viewer has no part in the event" do
    assert Membership.status(event(main_list: [other()]), "tok", nil, false) == nil
  end

  test "participating on the main list, matched by device token or user" do
    assert Membership.status(event(main_list: [mine()]), "tok", nil, false) == :participating

    by_user = %Attendee{name: "Eu", user_id: 7}
    assert Membership.status(event(main_list: [by_user]), nil, 7, false) == :participating
  end

  test "waiting on the waiting list" do
    assert Membership.status(event(wait_list: [mine()]), "tok", nil, false) == :waiting
  end

  test "organizing when the caller says so and the viewer isn't on a list" do
    assert Membership.status(event(main_list: [other()]), nil, nil, true) == :organizing
    assert Membership.status(event(main_list: [mine()]), "tok", nil, true) == :participating
  end

  describe "caloteiro" do
    test "an unpaid row on a payments-only event with a price" do
      assert Membership.status(
               event(status: :payments_only, main_list: [mine()]),
               "tok",
               nil,
               false
             ) ==
               :caloteiro
    end

    test "not once paid" do
      event = event(status: :payments_only, main_list: [mine(paid: true)])
      assert Membership.status(event, "tok", nil, false) == :participating
    end

    test "not on a free event" do
      event = event(status: :payments_only, price_cents: nil, main_list: [mine()])
      assert Membership.status(event, "tok", nil, false) == :participating
    end

    test "not while signups are still open" do
      assert Membership.status(event(main_list: [mine()]), "tok", nil, false) == :participating
    end

    test "under Dividir no final, only when the plan has the viewer sending money" do
      base = [status: :payments_only, split_method: :settle_up, price_cents: nil]

      receiver = event(base ++ [main_list: [mine(contributed_cents: 10_000), other()]])
      assert Membership.status(receiver, "tok", nil, false) == :participating

      sender = event(base ++ [main_list: [mine(), other(contributed_cents: 10_000)]])
      assert Membership.status(sender, "tok", nil, false) == :caloteiro
    end
  end
end
