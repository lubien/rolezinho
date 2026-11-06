defmodule RolezinhoWeb.Components.UI.StatusPill do
  @moduledoc """
  The state of an event, as a pill.

  Paired source: the tones map to `Rolezinho.Event` statuses plus the two derived
  states (`open`/`full`) that come from comparing the list against its capacity.
  A new event status requires a tone here.
  """
  use Phoenix.Component

  @doc """
  Renders the status pill.

  ## Examples

      <.status_pill tone="open">Slots open</.status_pill>
      <.status_pill tone="full">List full</.status_pill>
      <.status_pill tone="done">Closed</.status_pill>
      <.status_pill tone="debt">Pix pending</.status_pill>
  """
  attr :tone, :string, default: "open", values: ~w(open full done debt payments_only maybe member)
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block, required: true

  def status_pill(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex shrink-0 items-center whitespace-nowrap rounded-row px-3 py-[7px] text-[11px] font-bold",
        tone_classes(@tone),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp tone_classes("open"), do: "bg-tint text-accent-ink"
  defp tone_classes("full"), do: "bg-ink text-ink-content"
  defp tone_classes("done"), do: "bg-ink/[0.08] text-muted"
  defp tone_classes("debt"), do: "bg-danger text-danger-content"
  defp tone_classes("payments_only"), do: "bg-warning text-warning-content"
  # "maybe" is the "averiguando resenha" tentative status. Solid info blue
  # keeps it visibly distinct from the other four tones (green tint, black,
  # gray, yellow, red) on a card row.
  defp tone_classes("maybe"), do: "bg-info text-info-content"
  # "member" marks the viewer's own rolês on the home (Participando, Na
  # espera, Organizando): the same blue as the card's border, tinted rather
  # than solid so it doesn't read as the "maybe" status.
  defp tone_classes("member"), do: "bg-info/15 text-info"
end
