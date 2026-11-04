defmodule Rolezinho.Event.SettlementTest do
  use ExUnit.Case, async: true

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.Settlement

  defp event(people) do
    list =
      Enum.map(people, fn
        {name, cents} -> %Attendee{name: name, contributed_cents: cents}
        {name, cents, paid} -> %Attendee{name: name, contributed_cents: cents, paid: paid}
      end)

    %Event{split_method: :settle_up, main_list: list}
  end

  defp transfers(plan), do: Enum.map(plan.transfers, &{&1.from.name, &1.to.name, &1.cents})

  defp nobody_else(names), do: Enum.map(names, &{&1, 0})

  describe "plan/1" do
    test "two payers and eight who spent nothing: R$ 32 each" do
      plan =
        event([{"Ana", 20_000}, {"Bruno", 12_000}] ++ nobody_else(~w(C D E F G H I J)))
        |> Settlement.plan()

      assert plan.total_cents == 32_000
      assert plan.share_cents == 3200

      assert transfers(plan) == [
               {"C", "Ana", 3200},
               {"D", "Ana", 3200},
               {"E", "Ana", 3200},
               {"F", "Ana", 3200},
               {"G", "Ana", 3200},
               {"H", "Ana", 800},
               {"H", "Bruno", 2400},
               {"I", "Bruno", 3200},
               {"J", "Bruno", 3200}
             ]
    end

    test "a single payer gets everyone's share" do
      plan = event([{"Ana", 20_000}] ++ nobody_else(~w(B C D E))) |> Settlement.plan()

      assert transfers(plan) == [
               {"B", "Ana", 4000},
               {"C", "Ana", 4000},
               {"D", "Ana", 4000},
               {"E", "Ana", 4000}
             ]
    end

    test "a payer below the share still owes the difference" do
      plan =
        event([{"Ana", 30_000}, {"Bruno", 2000}] ++ nobody_else(~w(C D E F G H I J)))
        |> Settlement.plan()

      assert {"Bruno", "Ana", 1200} in transfers(plan)
      assert Enum.all?(plan.transfers, &(&1.to.name == "Ana"))
      assert Enum.sum(Enum.map(plan.transfers, & &1.cents)) == 30_000 - 3200
    end

    test "someone who spent exactly their share is out of the plan" do
      plan = event([{"Ana", 6000}, {"Bruno", 3000}, {"Carla", 0}]) |> Settlement.plan()

      assert transfers(plan) == [{"Carla", "Ana", 3000}]
    end

    test "nobody owes anything when everyone spent the same" do
      plan = event([{"Ana", 5000}, {"Bruno", 5000}]) |> Settlement.plan()

      assert plan.transfers == []
    end

    test "no contributions means no plan" do
      plan = event(nobody_else(~w(Ana Bruno))) |> Settlement.plan()

      assert plan.total_cents == 0
      assert plan.transfers == []
    end

    test "leftover cents go to the first people so shares add up to the total" do
      plan = event([{"Ana", 10_000}, {"Bruno", 0}, {"Carla", 0}]) |> Settlement.plan()

      assert Enum.map(plan.people, & &1.share_cents) == [3334, 3333, 3333]
      assert transfers(plan) == [{"Bruno", "Ana", 3333}, {"Carla", "Ana", 3333}]
    end

    test "empty slots are skipped and indexes are list positions" do
      plan =
        Settlement.plan(%Event{
          main_list: [
            %Attendee{name: "Ana", contributed_cents: 1000},
            %Attendee{name: ""},
            %Attendee{name: "Carla"}
          ]
        })

      assert Enum.map(plan.people, &{&1.name, &1.index}) == [{"Ana", 1}, {"Carla", 3}]
    end

    test "an empty list has no share" do
      assert %{share_cents: nil, people: [], transfers: []} =
               Settlement.plan(%Event{main_list: []})
    end

    test "transfers always settle every balance exactly" do
      for seed <- 1..200 do
        :rand.seed(:exsss, {seed, seed, seed})
        count = Enum.random(1..12)
        people = for i <- 1..count, do: {"P#{i}", Enum.random([0, 0, 0, Enum.random(1..50_000)])}
        plan = Settlement.plan(event(people))

        net =
          Enum.reduce(plan.transfers, %{}, fn t, acc ->
            acc
            |> Map.update(t.from.index, t.cents, &(&1 + t.cents))
            |> Map.update(t.to.index, -t.cents, &(&1 - t.cents))
          end)

        for person <- plan.people do
          assert person.balance_cents + Map.get(net, person.index, 0) == 0
        end

        assert length(plan.transfers) <= max(count - 1, 0)
      end
    end
  end

  describe "by_sender/1" do
    test "groups a split transfer under its sender, in list order" do
      plan =
        event([{"Ana", 20_000}, {"Bruno", 12_000}] ++ nobody_else(~w(C D E F G H I J)))
        |> Settlement.plan()

      {sender, transfers} =
        plan |> Settlement.by_sender() |> Enum.find(&(elem(&1, 0).name == "H"))

      assert sender.name == "H"
      assert Enum.map(transfers, &{&1.to.name, &1.cents}) == [{"Ana", 800}, {"Bruno", 2400}]
    end
  end
end
