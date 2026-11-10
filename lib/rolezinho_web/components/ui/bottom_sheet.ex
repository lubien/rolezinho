defmodule RolezinhoWeb.Components.UI.BottomSheet do
  @moduledoc """
  A sheet that rises from the bottom of the screen: join the list, remove,
  share.

  Bottom-anchored because the thumb reaches the bottom of a phone, not the
  middle. A destructive action always sits on the right, in the danger tone.

  Show and hide it with `JS` commands rather than a hook — `JS` is DOM-patch
  aware, so the state survives a re-render from the server (see
  `.claude/rules/liveview.md`).
  """
  use Phoenix.Component

  import RolezinhoWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  @doc """
  Renders the sheet.

  ## Examples

      <.bottom_sheet id="join" title="Join the list">
        <.text_field label="Name" name="name" />
        <:actions>
          <.action_button phx-click="confirm">Confirm</.action_button>
        </:actions>
      </.bottom_sheet>

      <button phx-click={RolezinhoWeb.Components.UI.BottomSheet.show("join")}>Open</button>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :open, :boolean, default: false, doc: "renders already open (for stories and tests)"
  attr :on_cancel, JS, default: %JS{}
  attr :class, :any, default: nil

  slot :inner_block
  slot :actions, doc: "the action row at the bottom of the sheet"

  def bottom_sheet(assigns) do
    ~H"""
    <div
      id={@id}
      class={["relative z-50", not @open && "hidden", @class]}
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={hide(@on_cancel, @id)}
      phx-key="escape"
    >
      <div
        id={"#{@id}-backdrop"}
        class="fixed inset-0 bg-ink/45 transition-opacity duration-200"
        aria-hidden="true"
      />
      <!--
        `bg-base-100` (not `bg-white`) so the panel surface inverts per
        theme — see the `@theme` block in `assets/css/app.css`. A literal
        `bg-white` would stay white under `[data-theme="dark"]` and clash
        with the near-white `text-ink` used inside the sheet.
      -->
      <div class="fixed inset-x-0 bottom-0 flex justify-center">
        <div
          id={"#{@id}-panel"}
          phx-click-away={hide(@on_cancel, @id)}
          class={[
            "flex max-h-[85dvh] w-full max-w-lg flex-col rounded-t-panel bg-base-100 p-4 shadow-sheet",
            "transition-transform duration-[260ms] ease-[cubic-bezier(.2,.8,.2,1)]",
            "motion-reduce:transition-none"
          ]}
        >
          <%!-- Capped at 85% of the screen so a strip of backdrop always shows
               (tapping it closes), with the header and the actions pinned and
               only the body scrolling. A long share text used to push the top
               controls and the actions off screen. --%>
          <div class="mx-auto mb-3 h-1 w-9 shrink-0 rounded-full bg-ink/15" aria-hidden="true" />
          <div class="flex shrink-0 items-start gap-3">
            <div class="min-w-0 flex-1">
              <h2 id={"#{@id}-title"} class="text-sm font-extrabold">{@title}</h2>
              <p :if={@description} class="mt-1.5 text-xs leading-relaxed text-muted">
                {@description}
              </p>
            </div>
            <button
              type="button"
              id={"#{@id}-close"}
              phx-click={hide(@on_cancel, @id)}
              class="-mr-1.5 -mt-1.5 grid size-9 shrink-0 place-items-center rounded-full text-muted focus-visible:outline-2 focus-visible:outline-accent"
              aria-label="Fechar"
            >
              <.icon name="tabler-x" class="size-5" />
            </button>
          </div>
          <div
            :if={@inner_block != []}
            class="mt-3.5 min-h-0 flex-1 overflow-y-auto overscroll-contain"
          >
            {render_slot(@inner_block)}
          </div>
          <div :if={@actions != []} class="mt-3.5 flex shrink-0 gap-2">{render_slot(@actions)}</div>
        </div>
      </div>
    </div>
    """
  end

  @doc "Shows the sheet with the given id."
  def show(js \\ %JS{}, id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-panel",
      # `flex`, not JS.show's default `block`: the panel is a flex column, and
      # that is what lets the body shrink and scroll under the height cap.
      display: "flex",
      transition: {"ease-out duration-[260ms]", "translate-y-full", "translate-y-0"}
    )
  end

  @doc "Hides the sheet with the given id."
  def hide(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-panel",
      transition: {"ease-in duration-200", "translate-y-0", "translate-y-full"}
    )
    |> JS.hide(to: "##{id}", transition: {"duration-200", "opacity-100", "opacity-0"})
  end
end
