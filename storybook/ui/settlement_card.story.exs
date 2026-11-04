defmodule Storybook.UI.SettlementCard do
  use PhoenixStorybook.Story, :component

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.Settlement

  def function, do: &RolezinhoWeb.Components.UI.SettlementCard.settlement_card/1

  def template do
    """
    <div class="max-w-sm bg-canvas p-3" psb-code-hidden>
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :two_payers,
        description:
          "Ana spent R$ 200 and Bruno R$ 120; 8 others nothing. R$ 32 each. Hugo splits his " <>
            "part across both. Carla, Davi and Iris have sent theirs.",
        attributes: %{plan: plan(two_payers()), editable: MapSet.new([5])}
      },
      %Variation{
        id: :nobody_yet,
        description: "Nobody has recorded spending yet.",
        attributes: %{plan: plan(for n <- ~w(Ana Bruno Carla), do: {n, 0, false})}
      }
    ]
  end

  defp two_payers do
    [{"Ana", 20_000, false}, {"Bruno", 12_000, false}, {"Carla", 0, true}, {"Davi", 0, true}] ++
      for(n <- ~w(Edu Fê Gabi Hugo), do: {n, 0, false}) ++
      [{"Iris", 0, true}, {"João", 0, false}]
  end

  defp plan(people) do
    list =
      for {name, cents, paid} <- people,
          do: %Attendee{name: name, contributed_cents: cents, paid: paid}

    Settlement.plan(%Event{split_method: :settle_up, main_list: list})
  end
end
