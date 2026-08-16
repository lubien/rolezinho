defmodule RolezinhoWeb.HomeLive do
  @moduledoc """
  The listing of open events.

  Ordered by when they happen, not by when they were created: someone opening
  this screen wants to know what is next, and an event that already passed is
  the least useful thing to put at the top.

  The category filter only appears once there is enough to filter — a row of
  chips above three cards is furniture, not navigation.
  """
  use RolezinhoWeb, :live_view

  alias Rolezinho.Event
  alias Rolezinho.Events

  # Below this, scanning the list is faster than filtering it.
  defp filter_threshold, do: 4

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe_home()

    {:ok,
     socket
     |> assign(:page_title, "Rolezinhos")
     |> assign(:category, "all")
     |> load_events()}
  end

  @impl true
  def handle_info(:home_changed, socket), do: {:noreply, load_events(socket)}

  @impl true
  def handle_event("filter", %{"id" => category}, socket) do
    {:noreply, socket |> assign(:category, category) |> apply_filter()}
  end

  defp load_events(socket) do
    socket |> assign(:events, Events.list_open()) |> apply_filter()
  end

  defp apply_filter(socket) do
    events = socket.assigns.events

    socket
    |> assign(:categories, categories(events))
    |> assign(:visible, filter(events, socket.assigns.category))
  end

  defp filter(events, "all"), do: events
  defp filter(events, category), do: Enum.filter(events, &(&1.category == category))

  defp categories(events) do
    events
    |> Enum.map(& &1.category)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin?={@current_admin?} page_title={@page_title}>
      <div id="home" phx-hook=".RecentEvents" class="mx-auto max-w-[560px]">
        <header class="flex items-end justify-between gap-4">
          <div class="min-w-0">
            <h1 class="text-2xl font-extrabold tracking-tight">Rolezinhos</h1>
            <p class="mt-0.5 text-[13px] text-muted">Os rolês abertos por aqui</p>
          </div>
          <!-- Both destinations live here, next to the title. Two of them do not
               earn a permanent bar across the bottom of every screen, and the
               bottom strip is worth more to the action someone came to take. -->
          <div class="flex shrink-0 items-center gap-1.5">
            <.link
              navigate={~p"/me"}
              class="grid size-11 place-items-center rounded-full bg-ink/[0.06] text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
              aria-label="Suas preferências"
            >
              <.icon name="tabler-user-circle" class="size-5" />
            </.link>
            <.link
              navigate={~p"/criar"}
              class="grid size-11 place-items-center rounded-full bg-ink text-ink-content shadow-cta focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
              aria-label="Criar rolezinho"
            >
              <.icon name="tabler-plus" class="size-5" />
            </.link>
          </div>
        </header>

        <.filter_chips
          :if={length(@events) >= filter_threshold() and @categories != []}
          value={@category}
          on_select="filter"
          class="mt-4"
        >
          <:chip id="all" label="Todos" />
          <:chip :for={category <- @categories} id={category} label={category} />
        </.filter_chips>

        <.empty_state
          :if={@visible == []}
          icon="tabler-diamond"
          title={empty_title(@category)}
          class="mt-6"
        >
          {empty_body(@category)}
        </.empty_state>

        <ul :if={@visible != []} class="mt-4 space-y-2.5">
          <li :for={event <- @visible}>
            <.role_card
              id={"#{event.id}-role-card"}
              title={event.title}
              when_text={when_text(event)}
              category={event.category}
              status={status_for(event)}
              filled={filled_count(event)}
              capacity={event.main_capacity}
              names={attendee_names(event)}
              navigate={~p"/r/#{event.slug}"}
            />
          </li>
        </ul>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".RecentEvents">
        const KEY = "rolezinho:recent"

        export default {
          mounted() {
            // The listing shows what is open; this remembers what *this* device
            // has opened, which is the only history the app keeps. Slugs only —
            // titles and counts would go stale, and the server already has them.
            try {
              const seen = JSON.parse(localStorage.getItem(KEY) || "[]")
              if (!Array.isArray(seen)) localStorage.removeItem(KEY)
            } catch (_) { }
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp empty_title("all"), do: "Nenhum rolê por aqui"
  defp empty_title(_), do: "Nada nessa categoria"

  # Anyone can create now, so the empty state invites rather than explains the
  # wait.
  defp empty_body("all"), do: "Cria o primeiro e manda o link no grupo."
  defp empty_body(_category), do: "Tenta outra categoria."

  defp status_for(%Event{status: :payments_only}), do: "payments_only"
  defp status_for(%Event{status: :done}), do: "done"

  defp status_for(%Event{} = event) do
    if Event.main_full?(event), do: "full", else: "open"
  end

  defp when_text(%Event{starts_at: nil}), do: nil

  # Stored in UTC, read in Brasília: rendering the raw timestamp turns a 21h
  # event into "00h" of the following day, which is the wrong day and the wrong
  # hour to whoever is deciding whether to go.
  defp when_text(%Event{starts_at: starts_at}) do
    starts_at
    |> DateTime.add(-3 * 3600, :second)
    |> Calendar.strftime("%d/%m · %Hh")
  end

  defp filled_count(%Event{main_list: list}) do
    Enum.count(list, &(String.trim(&1.name) != ""))
  end

  defp attendee_names(%Event{main_list: list}) do
    list
    |> Enum.map(&String.trim(&1.name))
    |> Enum.reject(&(&1 == ""))
  end
end
