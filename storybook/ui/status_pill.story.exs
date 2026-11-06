defmodule Storybook.UI.StatusPill do
  use PhoenixStorybook.Story, :component

  def function, do: &RolezinhoWeb.Components.UI.StatusPill.status_pill/1

  def template do
    """
    <div class="rounded-cta bg-surface p-3.5 flex flex-wrap items-center gap-2" psb-code-hidden>
      <.psb-variation-group/>
    </div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :tones,
        description:
          "open and full are derived by comparing the list against its capacity; done and " <>
            "payments_only come from the event's status field.",
        variations: [
          %Variation{id: :open, attributes: %{tone: "open"}, slots: ["Slots open"]},
          %Variation{id: :full, attributes: %{tone: "full"}, slots: ["List full"]},
          %Variation{id: :done, attributes: %{tone: "done"}, slots: ["Closed"]},
          %Variation{
            id: :payments_only,
            attributes: %{tone: "payments_only"},
            slots: ["Payments only"]
          },
          %Variation{id: :debt, attributes: %{tone: "debt"}, slots: ["Pix pending"]},
          %Variation{id: :member, attributes: %{tone: "member"}, slots: ["Participando"]}
        ]
      }
    ]
  end
end
