defmodule RolezinhoWeb.Components.UI.RoleCard do
  @moduledoc """
  An event as it appears in the home listing.

  Carries the four things that decide whether someone taps: what it is, when it
  happens, who is already in, and whether there is still room. The occupancy bar
  repeats the counter visually — on a phone, in the sun, the bar reads faster
  than "17/18".
  """
  use Phoenix.Component

  import RolezinhoWeb.Components.UI.Avatar, only: [avatar_stack: 1]
  import RolezinhoWeb.Components.UI.ProgressBar, only: [progress_bar: 1]
  import RolezinhoWeb.Components.UI.StatusPill, only: [status_pill: 1]
  import RolezinhoWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders the card.

  ## Examples

      <.role_card
        title="Beach volleyball"
        when_text="Wednesday · 7pm to 9pm"
        category="Sport"
        status="open"
        filled={17}
        capacity={18}
        names={["Marcia", "Roberta", "Henrique"]}
        navigate={~p"/r/beach-volleyball"}
      />
  """
  attr :title, :string, required: true
  attr :when_text, :string, default: nil
  attr :category, :string, default: nil
  attr :category_initial, :string, default: nil

  attr :status, :string,
    default: nil,
    values: ~w(open full done debt payments_only maybe) ++ [nil]

  attr :status_label, :string, default: nil
  # Native-tooltip text on the status pill. Kept as the browser `title`
  # attribute on purpose: no JS, works everywhere, and screen readers
  # already announce it — exactly the small explainer this hint needs.
  attr :status_hint, :string, default: nil
  attr :filled, :integer, default: nil
  attr :capacity, :integer, default: nil
  attr :names, :list, default: []
  attr :navigate, :string, default: nil
  # Whether the rolê is unlisted (hidden from the public home). Rendered
  # as a tiny eye-off icon next to the status pill so the marker takes
  # a few pixels rather than a full pill of horizontal space.
  attr :hidden?, :boolean, default: false

  # The viewer's part in this rolê (`Rolezinho.Event.Membership.status/4`).
  # Any value draws the blue border and replaces the status pill: whether
  # *I* am in is what someone scanning the home is looking for.
  attr :member, :atom,
    default: nil,
    values: [nil, :caloteiro, :participating, :waiting, :organizing]

  # Rolês inside a group carry the group's name, so a grouped event on the
  # home still reads as part of its group.
  attr :group_name, :string, default: nil
  attr :class, :any, default: nil

  def role_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "block rounded-card bg-base-100 p-4 shadow-card",
        if(@member, do: "border-2 border-info", else: "border border-hairline"),
        "transition-transform active:scale-[.99]",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
        @class
      ]}
    >
      <div
        :if={@category || @status || @hidden? || @member || @group_name}
        class="flex items-center gap-2"
      >
        <span
          :if={@category}
          class="grid size-6 shrink-0 place-items-center rounded-lg bg-accent text-[11px] font-bold text-accent-content"
          aria-hidden="true"
        >
          {@category_initial || String.first(@category)}
        </span>
        <span
          :if={@category}
          class="min-w-0 truncate text-[10px] font-semibold uppercase tracking-wide text-muted"
        >
          {@category}
        </span>
        <span
          :if={@group_name}
          class="inline-flex min-w-0 items-center gap-1 rounded-row bg-ink/[0.06] px-2 py-1 text-[10px] font-bold text-ink"
        >
          <.icon name="tabler-users-group" class="size-3.5 shrink-0" />
          <span class="truncate">{@group_name}</span>
        </span>
        <span
          :if={@hidden?}
          class="ml-auto inline-flex shrink-0 items-center text-warning"
          title="Oculto: não aparece na home pública"
        >
          <.icon name="tabler-eye-off" class="size-4" />
          <span class="sr-only">Oculto</span>
        </span>
        <.status_pill
          :if={@member}
          tone={member_tone(@member)}
          class={[not @hidden? && "ml-auto"]}
        >
          {member_label(@member)}
        </.status_pill>
        <.status_pill
          :if={@status && !@member}
          tone={@status}
          class={[not @hidden? && "ml-auto"]}
          title={@status_hint}
        >
          {@status_label || default_status_label(@status)}
        </.status_pill>
      </div>

      <div class="mt-2 text-lg font-extrabold tracking-tight">{@title}</div>
      <div :if={@when_text} class="mt-0.5 text-xs text-muted">{@when_text}</div>

      <div :if={@names != [] || @filled} class="mt-3 flex items-center justify-between gap-2">
        <.avatar_stack
          :if={@names != []}
          names={@names}
          size="xs"
          max={3}
          ring_class="ring-base-100"
          class="shrink-0"
        />
        <span
          :if={@filled && @capacity}
          class="ml-auto shrink-0 whitespace-nowrap text-[11px] font-semibold text-muted"
        >
          {@filled}/{@capacity} confirmados
        </span>
      </div>

      <.progress_bar :if={@filled && @capacity} filled={@filled} capacity={@capacity} class="mt-2.5" />
    </.link>
    """
  end

  defp member_tone(:caloteiro), do: "debt"
  defp member_tone(_member), do: "member"

  defp member_label(:caloteiro), do: "Caloteiro"
  defp member_label(:participating), do: "Participando"
  defp member_label(:waiting), do: "Na espera"
  defp member_label(:organizing), do: "Organizando"

  defp default_status_label("open"), do: "Vagas abertas"
  defp default_status_label("full"), do: "Lista cheia"
  defp default_status_label("done"), do: "Encerrado"
  defp default_status_label("debt"), do: "Pix pendente"
  defp default_status_label("payments_only"), do: "Só pagamentos"
  defp default_status_label("maybe"), do: Rolezinho.Event.maybe_status_label()
end
