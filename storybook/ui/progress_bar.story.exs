defmodule Storybook.UI.ProgressBar do
  use PhoenixStorybook.Story, :component

  def function, do: &RolezinhoWeb.Components.UI.ProgressBar.progress_bar/1

  def template do
    """
    <div class="max-w-sm rounded-cta bg-surface p-3.5 flex flex-col gap-3.5" psb-code-hidden>
      <.psb-variation-group/>
    </div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :occupancy,
        description: "With a label it renders the header row and the counter.",
        variations: [
          %Variation{
            id: :almost_full,
            attributes: %{filled: 17, capacity: 18, label: "Main list"}
          },
          %Variation{id: :half, attributes: %{filled: 5, capacity: 10, label: "Main list"}},
          %Variation{id: :empty, attributes: %{filled: 0, capacity: 12, label: "Main list"}},
          %Variation{id: :full, attributes: %{filled: 18, capacity: 18, label: "Main list"}}
        ]
      },
      %Variation{
        id: :info,
        description: "The blue fill used on the viewer's own rolês on the home.",
        attributes: %{filled: 5, capacity: 10, tone: "info"}
      },
      %Variation{
        id: :bare,
        description: "Without a label it is just the bar — for use inside an event card.",
        attributes: %{filled: 9, capacity: 20}
      }
    ]
  end
end
