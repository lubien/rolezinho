defmodule RolezinhoWeb.Components.UI.ProgressBar do
  @moduledoc """
  How full a list is.

  What the paid check means is said by the count beside the list title ("4 de 6
  já pagaram") rather than by a legend. A legend of circle-plus-label pairs
  borrows the grammar of a filter, so it read as options to choose between.
  """
  use Phoenix.Component

  @doc """
  Renders the occupancy bar of a list.

  ## Examples

      <.progress_bar filled={17} capacity={18} />
      <.progress_bar filled={3} capacity={10} label="Main list" />
  """
  attr :filled, :integer, required: true
  attr :capacity, :integer, required: true
  attr :label, :string, default: nil, doc: "when given, renders the header row with the counter"

  attr :tone, :string,
    default: "accent",
    values: ~w(accent info),
    doc: "fill color; `info` marks the viewer's own rolês on the home"

  attr :class, :any, default: nil

  def progress_bar(assigns) do
    assigns = assign(assigns, :percent, percent(assigns.filled, assigns.capacity))

    ~H"""
    <div class={@class}>
      <div :if={@label} class="flex items-center justify-between">
        <span class="text-[13px] font-bold">{@label}</span>
        <span class="text-[11px] font-semibold text-muted">{@filled}/{@capacity}</span>
      </div>
      <div
        class={["h-[5px] overflow-hidden rounded-full bg-ink/[0.08]", @label && "mt-2"]}
        role="progressbar"
        aria-valuenow={@filled}
        aria-valuemin="0"
        aria-valuemax={@capacity}
        aria-label={@label || "List occupancy"}
      >
        <div
          class={["h-full rounded-full transition-[width]", fill_class(@tone)]}
          style={"width: #{@percent}%"}
        />
      </div>
    </div>
    """
  end

  defp percent(_filled, capacity) when capacity <= 0, do: 0

  defp percent(filled, capacity) do
    filled |> max(0) |> min(capacity) |> Kernel.*(100) |> div(capacity)
  end

  defp fill_class("info"), do: "bg-info"
  defp fill_class(_accent), do: "bg-accent"
end
