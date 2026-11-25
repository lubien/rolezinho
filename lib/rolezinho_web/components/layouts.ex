defmodule RolezinhoWeb.Layouts do
  @moduledoc """
  Holds layouts and related functionality used across the application.
  """
  use RolezinhoWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the app shell.

  Shaped for the one context this product actually has: a phone, held in one
  hand, opened from a link someone pasted into a group chat. So the frame is a
  single column and the content scrolls inside a viewport pinned to `dvh` —
  `vh` would put the bottom of the page under Safari's toolbar.

  The bottom of the frame belongs to the screen's own action, not to
  navigation. This app has two destinations, which is not enough to earn a
  permanent bar: a tab bar would spend the most reachable strip of the screen
  on switching between two places while the thing someone came to do — join the
  list — scrolled away above it. Screens pass that action through `:action`,
  where it stays put and clears the home indicator via the safe-area inset.

  On a desktop the same column simply centres. There is no wide layout, because
  a second column would be built for a reader this product does not have.
  """
  attr :flash, :map, required: true
  attr :current_admin?, :boolean, default: false
  # Signed-in user (or nil). Passed through so screens can render the avatar
  # and logout link in their header. Kept off `current_scope` on purpose: this
  # project has no `current_scope` (see AGENTS.md).
  attr :current_user, :any, default: nil
  attr :page_title, :string, default: nil

  slot :inner_block, required: true

  slot :action,
    doc: "pinned to the bottom of the viewport: the screen's primary action, never navigation"

  def app(assigns) do
    ~H"""
    <div class="flex h-dvh flex-col bg-canvas">
      <%!-- `relative z-10` puts everything rendered in the page — including the
           fixed bottom sheets — in a stacking layer above the action bar below.
           Without it, mobile browsers can paint the bar over an open sheet's
           buttons, since the bar comes later in the DOM. --%>
      <main class="relative z-10 flex-1 overflow-y-auto overscroll-contain px-5 pb-6 pt-[max(2rem,env(safe-area-inset-top))]">
        <div class="mx-auto max-w-[420px] md:max-w-[52rem] xl:max-w-[72rem]">
          {render_slot(@inner_block)}
        </div>
      </main>

      <%!-- Hidden while a bottom sheet is open (`BottomSheet.show/2`): on some
           mobile browsers the bar paints over an open sheet's buttons no matter
           the stacking order, so the sheet gets the bottom of the screen alone. --%>
      <div
        :if={@action != []}
        id="app-action-bar"
        class="shrink-0 border-t border-hairline bg-canvas px-5 pt-3 pb-[max(0.75rem,env(safe-area-inset-bottom))]"
      >
        <div class="mx-auto max-w-[420px] md:max-w-[52rem] xl:max-w-[72rem]">
          {render_slot(@action)}
        </div>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="tabler-refresh" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="tabler-refresh" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Dark/light theme toggle.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center border border-base-300 bg-base-200 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border border-base-300 bg-base-100 shadow-sm left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="relative flex p-2 cursor-pointer w-1/3 justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title="Sistema"
      >
        <.icon name="tabler-device-desktop" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative flex p-2 cursor-pointer w-1/3 justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Claro"
      >
        <.icon name="tabler-sun" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative flex p-2 cursor-pointer w-1/3 justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Escuro"
      >
        <.icon name="tabler-moon" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
