defmodule Storybook.UI.SplitMethodFields do
  use PhoenixStorybook.Story, :component

  def function, do: &RolezinhoWeb.Components.UI.SplitMethodFields.split_method_fields/1

  def template do
    """
    <div class="max-w-sm rounded-card bg-base-100 p-4" psb-code-hidden>
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :per_person,
        description: "The default: a fixed price per person.",
        attributes: %{form: form("per_person", %{"price" => "15"}), id: "split-per-person"}
      },
      %Variation{
        id: :total_split,
        description: "The amount field becomes the whole bill.",
        attributes: %{form: form("total_split", %{"total" => "300"}), id: "split-total"}
      },
      %Variation{
        id: :settle_up,
        description: "No amount field: attendees record what they spent.",
        attributes: %{form: form("settle_up", %{}), id: "split-settle"}
      }
    ]
  end

  defp form(method, extra),
    do: Phoenix.Component.to_form(Map.put(extra, "split_method", method), as: :event)
end
