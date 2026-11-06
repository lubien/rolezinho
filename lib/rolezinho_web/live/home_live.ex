defmodule RolezinhoWeb.HomeLive do
  @moduledoc """
  The listing of open events and public groups.

  Groups sit at the top of the list — they bundle a batch of events under one
  link, so visually representing them separately is what tells someone "that
  is a lot of things, not one thing". Ungrouped events follow.

  Ordered by when they happen, not by when they were created: someone opening
  this screen wants to know what is next, and an event that already passed is
  the least useful thing to put at the top.

  The category filter only appears once there is enough to filter — a row of
  chips above three cards is furniture, not navigation.
  """
  use RolezinhoWeb, :live_view

  alias Rolezinho.Event
  alias Rolezinho.Events
  alias Rolezinho.Group
  alias Rolezinho.Groups
  alias Rolezinho.Event.Membership
  alias Rolezinho.MultiShare
  alias RolezinhoWeb.Plugs.Participant
  alias RolezinhoWeb.Components.UI.BottomSheet

  # Below this, scanning the list is faster than filtering it.
  defp filter_threshold, do: 4

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe_home()

    {:ok,
     socket
     |> assign(:page_title, "Rolezinhos")
     |> assign(:category, "all")
     |> assign(:shareable_events, [])
     |> assign(:share_selected, nil)
     |> assign(:share_password?, false)
     |> load_events()}
  end

  @impl true
  def handle_info(:home_changed, socket), do: {:noreply, load_events(socket)}

  @impl true
  def handle_event("filter", %{"id" => category}, socket) do
    {:noreply, socket |> assign(:category, category) |> apply_filter()}
  end

  # Ids arrive from the client, so only ids of the caller's own shareable
  # events are honored — anything else is dropped before it can reach the
  # text.
  def handle_event("multi_share_toggle", %{"id" => id}, socket) do
    %{share_selected: selected, shareable_events: shareable} = socket.assigns

    selected =
      with {id, ""} <- Integer.parse(id),
           true <- Enum.any?(shareable, &(&1.id == id)) do
        toggle_member(selected, id)
      else
        _ -> selected
      end

    {:noreply, socket |> assign(:share_selected, selected) |> assign_multi_share_text()}
  end

  def handle_event("multi_share_toggle_password", _params, socket) do
    {:noreply,
     socket
     |> assign(:share_password?, not socket.assigns.share_password?)
     |> assign_multi_share_text()}
  end

  defp load_events(socket) do
    # The public listing plus the viewer's own rolês: created or joined while
    # signed in, or held by this browser's participant/organizer tokens.
    user_id = socket.assigns[:current_user_id]
    participants = socket.assigns[:participants] || %{}
    organizer_tokens = socket.assigns[:organizer_tokens] || %{}
    device_slugs = Enum.uniq(Map.keys(participants) ++ Map.keys(organizer_tokens))

    with_membership =
      user_id
      |> Events.list_home_for(device_slugs)
      |> Enum.map(fn event ->
        organizer? =
          Participant.organizer?(%{"organizer_tokens" => organizer_tokens}, event) or
            (is_integer(user_id) and event.created_by_user_id == user_id)

        {event, Membership.status(event, Map.get(participants, event.slug), user_id, organizer?)}
      end)
      |> Enum.filter(fn {event, member} -> listable?(event, member, socket) end)

    socket
    |> assign(:events, Enum.map(with_membership, &elem(&1, 0)))
    |> assign(:membership, Map.new(with_membership, fn {event, member} -> {event.id, member} end))
    |> assign(:groups, Groups.list_public())
    |> apply_filter()
    |> load_shareable(user_id)
  end

  # Everything starts selected; on a live refresh the existing selection is
  # kept, minus events that stopped being shareable, plus newly created ones.
  defp load_shareable(socket, user_id) do
    # Same group gate as the listing: an event inside a group this viewer
    # can't open doesn't get its title into the share sheet either.
    shareable =
      user_id
      |> Events.list_shareable_for()
      |> Enum.filter(&group_open?(&1, socket))

    ids = MapSet.new(shareable, & &1.id)

    selected =
      merge_selection(socket.assigns.share_selected, socket.assigns.shareable_events, ids)

    socket
    |> assign(:shareable_events, shareable)
    |> assign(:share_selected, selected)
    |> assign(:share_has_password?, Enum.any?(shareable, &Event.password_protected?/1))
    |> assign_multi_share_text()
  end

  defp merge_selection(nil, _previous, ids), do: ids

  defp merge_selection(selected, previous, ids) do
    new_ids = MapSet.difference(ids, MapSet.new(previous, & &1.id))
    selected |> MapSet.intersection(ids) |> MapSet.union(new_ids)
  end

  defp toggle_member(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp assign_multi_share_text(socket) do
    %{shareable_events: events, share_selected: selected, share_password?: password?} =
      socket.assigns

    text =
      events
      |> Enum.filter(&MapSet.member?(selected, &1.id))
      |> MultiShare.to_text(&event_url/1, include_password: password?)

    assign(socket, :multi_share_text, text)
  end

  defp event_url(%Event{slug: slug}), do: RolezinhoWeb.Endpoint.url() <> "/r/" <> slug

  # A device slug is only a candidate: without a real membership the event
  # stays off unless it is public anyway. A grouped event also needs its
  # group open to this viewer — a locked group renders nothing, anywhere
  # (SECURITY.md §3).
  defp listable?(%Event{group: %Group{}} = event, member, socket),
    do: not is_nil(member) and group_open?(event, socket)

  defp listable?(%Event{} = event, member, _socket), do: not is_nil(member) or public?(event)

  defp group_open?(%Event{group: %Group{} = group}, socket) do
    group_accessible?(
      group,
      socket.assigns.current_admin?,
      socket.assigns[:unlocked_groups],
      socket.assigns[:current_user_id]
    )
  end

  defp group_open?(%Event{}, _socket), do: true

  defp public?(%Event{} = event),
    do: event.status in Event.open_statuses() and not event.hidden and is_nil(event.group_id)

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

  # A group is "accessible" to the viewer when they can see its contents
  # without providing the password: admin, no password, creator, or a
  # session-unlock already recorded (persisted unlocks for signed-in users
  # get merged into `:unlocked_groups` upstream in `Plugs.User`).
  defp group_accessible?(group, admin?, unlocked_groups, current_user_id),
    do: Group.accessible?(group, admin?, unlocked_groups || MapSet.new(), current_user_id)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_admin?={@current_admin?}
      current_user={@current_user}
      page_title={@page_title}
    >
      <div id="home" phx-hook=".RecentEvents">
        <header class="flex items-end justify-between gap-4">
          <div class="min-w-0">
            <h1 class="text-2xl font-extrabold tracking-tight">Rolezinhos</h1>
            <p class="mt-0.5 text-[13px] text-muted">Os rolês abertos por aqui</p>
          </div>
          <!-- Destinations next to the title. The /me link becomes the
               signed-in user's GitHub avatar when logged in — same target,
               friendlier signal. Logout lives on the /me page itself now,
               not on the navbar. -->
          <div class="flex shrink-0 items-center gap-1.5">
            <button
              :if={@shareable_events != []}
              id="multi-share-btn"
              type="button"
              phx-click={BottomSheet.show("multi-share-sheet")}
              class="grid size-11 place-items-center rounded-full bg-ink/[0.06] text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
              aria-label="Compartilhar seus rolezinhos"
            >
              <.icon name="tabler-share" class="size-[18px]" />
            </button>
            <.me_link current_user={@current_user} />
            <.link
              navigate={~p"/g/criar"}
              class="grid size-11 place-items-center rounded-full bg-ink/[0.06] text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
              aria-label="Criar grupo"
            >
              <.icon name="tabler-users-group" class="size-5" />
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

        <ul
          :if={@groups != []}
          id="group-list"
          class="mt-4 grid grid-cols-1 gap-2.5 md:grid-cols-2 xl:grid-cols-3"
        >
          <li :for={group <- @groups}>
            <.link
              navigate={~p"/g/#{group.slug}"}
              class="flex items-center gap-3 rounded-card border border-hairline bg-base-100 p-4 shadow-card transition-transform active:scale-[.99]"
            >
              <div class="grid size-11 shrink-0 place-items-center rounded-[14px] bg-accent text-accent-content">
                <.icon name="tabler-users-group" class="size-5" />
              </div>
              <div class="min-w-0 flex-1">
                <p class="truncate text-[15px] font-extrabold tracking-tight">{group.name}</p>
                <p class="mt-0.5 truncate text-[11px] text-muted">
                  <span class="font-mono">/g/{group.slug}</span>
                  <!--
                    A password-protected group carries a live status on the
                    home listing: the same viewer sees "com senha" (neutral)
                    when they cannot open it and "com acesso" (success tone)
                    when they can. Admin, creator or session-unlocked all
                    count as "have access" via `Group.accessible?/4`.
                  -->
                  <span
                    :if={
                      Group.password_protected?(group) and
                        not group_accessible?(
                          group,
                          @current_admin?,
                          @unlocked_groups,
                          @current_user_id
                        )
                    }
                    class="ml-1.5"
                  >· com senha</span>
                  <span
                    :if={
                      Group.password_protected?(group) and
                        group_accessible?(
                          group,
                          @current_admin?,
                          @unlocked_groups,
                          @current_user_id
                        )
                    }
                    class="ml-1.5 text-success"
                  >· com acesso</span>
                </p>
              </div>
              <.icon name="tabler-chevron-right" class="size-4 shrink-0 text-ink/30" />
            </.link>
          </li>
        </ul>

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
          :if={@visible == [] and @groups == []}
          icon="tabler-diamond"
          title={empty_title(@category)}
          class="mt-6"
        >
          {empty_body(@category)}
        </.empty_state>

        <ul
          :if={@visible != []}
          class="mt-4 grid grid-cols-1 gap-2.5 md:grid-cols-2 xl:grid-cols-3"
        >
          <li :for={event <- @visible}>
            <.role_card
              title={event.title}
              when_text={when_text(event)}
              category={event.category}
              status={status_for(event)}
              status_hint={status_hint(event)}
              hidden?={event.hidden}
              filled={filled_count(event)}
              capacity={event.main_capacity}
              names={attendee_names(event)}
              member={@membership[event.id]}
              group_name={event.group && event.group.name}
              navigate={~p"/r/#{event.slug}"}
            />
          </li>
        </ul>
      </div>

      <.bottom_sheet
        :if={@shareable_events != []}
        id="multi-share-sheet"
        title="Mandar seus rolezinhos"
      >
        <ul id="multi-share-list" class="max-h-56 space-y-1 overflow-y-auto">
          <li :for={event <- @shareable_events}>
            <label class="flex min-h-11 items-center gap-2.5 rounded-row px-2 py-1.5 active:bg-ink/[0.04]">
              <input
                id={"multi-share-event-#{event.id}"}
                type="checkbox"
                class={checkbox_class()}
                phx-click="multi_share_toggle"
                phx-value-id={event.id}
                checked={MapSet.member?(@share_selected, event.id)}
              />
              <span class="min-w-0 flex-1 truncate text-[13px] font-semibold">{event.title}</span>
              <.icon
                :if={Event.password_protected?(event)}
                name="tabler-lock"
                class="size-3.5 shrink-0 text-muted"
              />
              <span :if={when_text(event)} class="shrink-0 text-[11px] text-muted">
                {when_text(event)}
              </span>
            </label>
          </li>
        </ul>

        <label
          :if={@share_has_password?}
          class="mt-3 flex items-center gap-2.5 rounded-row bg-tint px-3 py-2.5"
        >
          <input
            id="multi-share-password-toggle"
            type="checkbox"
            class={checkbox_class()}
            phx-click="multi_share_toggle_password"
            checked={@share_password?}
          />
          <span class="text-xs font-semibold">Incluir as senhas no texto</span>
        </label>

        <.share_preview text={@multi_share_text} class="mt-3" />

        <:actions>
          <button
            id="multi-share-copy-btn"
            type="button"
            phx-hook=".CopyText"
            data-text={@multi_share_text}
            data-copied-label="Copiado!"
            class="flex-1 rounded-row bg-ink/[0.06] py-3 text-xs font-bold text-ink"
          >
            Copiar
          </button>
          <button
            id="multi-share-share-btn"
            type="button"
            phx-hook=".ShareText"
            data-title="Rolezinhos ativos"
            data-text={@multi_share_text}
            class="flex-1 rounded-row bg-ink py-3 text-xs font-bold text-ink-content"
          >
            Compartilhar
          </button>
        </:actions>
      </.bottom_sheet>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
        export default {
          mounted() {
            this.el.addEventListener("click", async () => {
              const done = this.el.dataset.copiedLabel || "Copiado!"
              try {
                await navigator.clipboard.writeText(this.el.dataset.text || "")
                this.flash(done)
              } catch (_) {
                this.flash("Não deu pra copiar")
              }
            })
          },
          flash(msg) {
            const original = this.el.innerHTML
            this.el.innerText = msg
            setTimeout(() => { this.el.innerHTML = original }, 1500)
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ShareText">
        export default {
          mounted() {
            this.el.addEventListener("click", async () => {
              const title = this.el.dataset.title || "Rolezinho"
              const text = this.el.dataset.text || ""
              if (navigator.share) {
                try { await navigator.share({ title, text }) } catch (_) {}
              } else {
                try {
                  await navigator.clipboard.writeText(text)
                  const original = this.el.innerHTML
                  this.el.innerText = "Copiado!"
                  setTimeout(() => { this.el.innerHTML = original }, 1500)
                } catch (_) {}
              }
            })
          }
        }
      </script>

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
  defp status_for(%Event{status: :maybe}), do: "maybe"

  defp status_for(%Event{} = event) do
    if Event.main_full?(event), do: "full", else: "open"
  end

  # The tooltip explaining what "Averiguando Resenha" means. Only the
  # tentative status carries one — the other pills speak for themselves
  # ("Vagas abertas", "Lista cheia") and don't need a hover.
  defp status_hint(%Event{status: :maybe}), do: Event.maybe_status_hint()
  defp status_hint(%Event{}), do: nil

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

  # The /me destination in the navbar. When signed in, the user's GitHub
  # avatar stands in for the generic user-circle icon — same target, same
  # size (48-px hit area), just a more personal signal that they're logged
  # in. Logout lives on the /me screen itself, not here: a destructive
  # action that clears the session should not be one tap away from the
  # home page.
  attr :current_user, :any, default: nil

  # No background tint under the avatar — the image already fills the chip.
  # Falls back to the pale ink chip when signed out or when GitHub did not
  # provide an avatar URL (private profiles).
  defp me_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/me"}
      class={[
        "grid size-11 place-items-center rounded-full text-ink",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
        if(@current_user && @current_user.avatar_url, do: "", else: "bg-ink/[0.06]")
      ]}
      aria-label={me_link_label(@current_user)}
    >
      <%= if @current_user && @current_user.avatar_url do %>
        <img
          src={@current_user.avatar_url}
          alt={"Avatar de #{Rolezinho.Accounts.User.display_name(@current_user)}"}
          class="size-9 rounded-full ring-1 ring-ink/10"
          referrerpolicy="no-referrer"
        />
      <% else %>
        <.icon name="tabler-user-circle" class="size-5" />
      <% end %>
    </.link>
    """
  end

  defp me_link_label(nil), do: "Suas preferências"

  defp me_link_label(user) do
    "Suas preferências (conectado como #{Rolezinho.Accounts.User.display_name(user)})"
  end
end
