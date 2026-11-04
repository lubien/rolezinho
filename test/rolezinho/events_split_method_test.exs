defmodule Rolezinho.EventsSplitMethodTest do
  use Rolezinho.DataCase, async: true

  alias Rolezinho.Event
  alias Rolezinho.Events

  defp create(overrides) do
    params =
      Map.merge(
        %{
          "title" => "Rolê",
          "slug" => "sm-#{System.unique_integer([:positive])}",
          "main_size" => "3",
          "wait_size" => "0"
        },
        overrides
      )

    {:ok, event} = Events.create(params, admin?: true)
    event
  end

  describe "create/2" do
    test "defaults to :per_person" do
      assert create(%{"price" => "15"}).split_method == :per_person
    end

    test "stores the method and the total" do
      event = create(%{"split_method" => "total_split", "total" => "300"})

      assert event.split_method == :total_split
      assert event.total_cents == 30_000
    end

    test "an unknown method falls back to :per_person" do
      assert create(%{"split_method" => "free_money"}).split_method == :per_person
    end
  end

  describe "update_payment/2" do
    test "keeps the method and total when the params leave them out" do
      event = create(%{"split_method" => "total_split", "total" => "300"})

      {:ok, updated} = Events.update_payment(event, %{"price" => ""})

      assert updated.split_method == :total_split
      assert updated.total_cents == 30_000
    end

    test "switches the method" do
      event = create(%{"price" => "15"})

      {:ok, updated} =
        Events.update_payment(event, %{"split_method" => "per_seat", "price" => "15"})

      assert updated.split_method == :per_seat
    end
  end

  describe "to_text/3" do
    test "adds the payment line after the header" do
      event = create(%{"split_method" => "per_seat", "price" => "15"})

      assert Event.to_text(event) =~ "Rolê\n\nR$ 15 por pessoa\n\n3 vagas"
    end

    test "leaves the payment line out with the description" do
      event = create(%{"price" => "15"})

      refute Event.to_text(event, nil, hide_description: true) =~ "por pessoa"
    end

    test "has no payment line for a free event" do
      refute Event.to_text(create(%{})) =~ "por pessoa"
    end
  end

  describe "set_contribution/3" do
    setup do
      event = create(%{"split_method" => "settle_up"})
      {:ok, event, _} = Events.add_party(event, "Ana", 1, participant_id: "tok")
      %{event: event}
    end

    test "parses what the visitor typed", %{event: event} do
      {:ok, event} = Events.set_contribution(event, 1, "R$ 32,50")
      assert hd(event.main_list).contributed_cents == 3250
    end

    test "blank clears to zero", %{event: event} do
      {:ok, event} = Events.set_contribution(event, 1, "200")
      {:ok, event} = Events.set_contribution(event, 1, "")
      assert hd(event.main_list).contributed_cents == 0
    end

    test "rejects garbage and absurd amounts", %{event: event} do
      assert {:error, :invalid_amount} = Events.set_contribution(event, 1, "muito")
      assert {:error, :invalid_amount} = Events.set_contribution(event, 1, "100001")
    end
  end
end
