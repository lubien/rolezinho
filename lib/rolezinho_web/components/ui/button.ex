defmodule RolezinhoWeb.Components.UI.Button do
  @moduledoc """
  The screen's action button.

  Named `action_button/1` to stay distinct from the generic
  `RolezinhoWeb.CoreComponents.button/1`; this is the full-width, thumb-reach
  button the design system puts at the bottom of a screen.

  There is one `primary` per screen (see `DESIGN.md`, section 5). `outline` is the
  escape hatch next to it ("Just look at the list"), and `ghost` is the quiet
  dismissal ("Not now").
  """
  use Phoenix.Component

  @doc """
  Renders the action button.

  Renders an `<a>` when given `href`/`navigate`/`patch`, and a `<button>`
  otherwise.

  ## Examples

      <.action_button phx-click="join">Join the list</.action_button>
      <.action_button variant="outline">Just look at the list</.action_button>
      <.action_button variant="ghost">Not now</.action_button>
      <.action_button loading>Joining</.action_button>
  """
  attr :variant, :string, default: "primary", values: ~w(primary outline ghost danger)

  attr :loading, :boolean,
    default: false,
    doc: "shows the loading label and blocks the tap"

  attr :full_width, :boolean, default: true, doc: "false renders an inline button"
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled form type)

  slot :inner_block, required: true

  def action_button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :anchor?, not is_nil(rest[:href] || rest[:navigate] || rest[:patch]))

    ~H"""
    <.link :if={@anchor?} class={[classes(@variant, @full_width, @loading), @class]} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    <button
      :if={not @anchor?}
      class={[classes(@variant, @full_width, @loading), @class]}
      aria-busy={@loading && "true"}
      disabled={@loading || @rest[:disabled]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp classes(variant, full_width, loading) do
    [
      "inline-flex items-center justify-center gap-2 font-bold transition-transform",
      "active:scale-[.97]",
      "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
      "disabled:opacity-40 disabled:pointer-events-none",
      full_width && "w-full",
      loading && "pointer-events-none",
      variant_classes(variant)
    ]
  end

  # min-h-11 is the 44px touch target floor from DESIGN.md, section 4.
  defp variant_classes("primary") do
    "min-h-11 rounded-cta px-4 py-4 text-[15px] bg-ink text-ink-content shadow-cta"
  end

  defp variant_classes("outline") do
    "min-h-11 rounded-cta px-4 py-3.5 text-[15px] border-[1.5px] border-ink/15 text-ink"
  end

  defp variant_classes("ghost") do
    "min-h-11 px-2 py-1 text-[13px] font-semibold text-muted underline"
  end

  # The destructive confirmation inside a sheet. It always sits to the right of the
  # way out, so the thumb reaches "cancel" first (see DESIGN.md, section 5).
  defp variant_classes("danger") do
    "min-h-11 rounded-cta px-4 py-4 text-[15px] bg-danger text-danger-content"
  end
end
