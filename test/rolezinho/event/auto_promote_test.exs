defmodule Rolezinho.Event.AutoPromoteTest do
  use ExUnit.Case, async: true

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee

  defp event(attrs) do
    struct!(
      %Event{
        status: :active,
        auto_promote: true,
        main_capacity: 3,
        main_list: [%Attendee{name: "Ana"}, %Attendee{name: "Bia"}, %Attendee{}],
        wait_list: [%Attendee{name: "Caio", paid: true}, %Attendee{name: "Duda"}]
      },
      attrs
    )
  end

  defp names(list), do: list |> Enum.map(& &1.name) |> Enum.reject(&(&1 == ""))

  describe "fill_from_waitlist/2" do
    test "moves the head of the queue into a free spot, unpaid" do
      filled = Event.fill_from_waitlist(event([]), 1)

      assert names(filled.main_list) == ["Ana", "Bia", "Caio"]
      assert names(filled.wait_list) == ["Duda"]
      refute Enum.find(filled.main_list, &(&1.name == "Caio")).paid
    end

    test "fills several spots in queue order and stops when the queue runs out" do
      event = event(main_list: [%Attendee{name: "Ana"}, %Attendee{}, %Attendee{}])
      filled = Event.fill_from_waitlist(event, 5)

      assert names(filled.main_list) == ["Ana", "Caio", "Duda"]
      assert filled.wait_list == []
    end

    test "fills only as many spots as asked" do
      event = event(main_list: [%Attendee{name: "Ana"}, %Attendee{}, %Attendee{}])

      assert names(Event.fill_from_waitlist(event, 1).main_list) == ["Ana", "Caio"]
    end

    test "does nothing when the event didn't opt in" do
      event = event(auto_promote: false)
      assert Event.fill_from_waitlist(event, 1) == event
    end

    test "does nothing once signups are closed or the event is over" do
      for status <- [:payments_only, :done] do
        event = event(status: status)
        assert Event.fill_from_waitlist(event, 1) == event
      end
    end

    test "works for an event still being decided (:maybe)" do
      assert names(Event.fill_from_waitlist(event(status: :maybe), 1).main_list) ==
               ["Ana", "Bia", "Caio"]
    end
  end
end
