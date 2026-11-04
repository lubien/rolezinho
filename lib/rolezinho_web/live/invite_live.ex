defmodule RolezinhoWeb.InviteLive do
  @moduledoc """
  The screen a shared link opens for someone who has not joined yet.

  It answers the question that decides everything — "are my people going?" —
  before asking for anything (RN-42). The list itself is a working surface, full
  of checks and rows; landing on it cold puts the decision behind a wall of
  detail that only matters once you are in.

  Two ways out, deliberately: joining, and looking without joining. Someone who
  only wants to know where it is should not have to put their name on a list to
  find out.
  """
  use RolezinhoWeb, :live_view

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.Cash
  alias Rolezinho.Event.Meta
  alias Rolezinho.Event.Policy
  alias Rolezinho.Events
  alias RolezinhoWeb.Components.UI.BottomSheet
  alias RolezinhoWeb.Plugs.Participant

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Events.find(slug, visibility: :public) do
      %Event{} = event -> mount_event(socket, event)
      nil -> {:ok, socket |> put_flash(:error, "Rolezinho não encontrado.") |> to_home()}
    end
  end

  defp mount_event(socket, %Event{} = event) do
    if connected?(socket), do: Events.subscribe(event.slug)

    {:ok, assign_event(socket, event)}
  end

  @impl true
  def handle_info({:event_updated, %Event{} = event}, socket) do
    {:noreply, assign_event(socket, event)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_event(socket, %Event{} = event) do
    unlocked? = unlocked?(socket, event)
    participant_id = Map.get(socket.assigns[:participants] || %{}, event.slug)
    user_id = socket.assigns[:current_user_id]
    {meta, _rest} = Meta.extract(event.header)

    socket
    |> assign(:page_title, event.title)
    |> assign(:event, event)
    |> assign(:unlocked?, unlocked?)
    |> assign(:participant_id, participant_id)
    |> assign(:joined?, joined?(event, participant_id, user_id))
    |> assign(:confirmed, confirmed_names(event, unlocked?))
    |> assign(:filled, filled_count(event))
    |> assign(:local, if(unlocked?, do: event.local || meta.local))
    |> assign(:when_text, when_text(event, meta))
    |> assign(:amount, Cash.format_amount(Cash.per_person_cents(event)))
    |> assign(:can_join?, can_join?(socket, event, participant_id, user_id))
    |> assign(:party_room, party_room(event))
    |> assign(:extra_fields, extra_fields(event))
  end

  defp extra_fields(%Event{} = event) do
    event |> Events.form_fields() |> Enum.reject(& &1.locked)
  end

  # The password gates this screen exactly as it gates the list: someone without
  # it sees the invitation, not the names or the address (RN-41).
  defp unlocked?(socket, %Event{} = event) do
    socket.assigns.current_admin? or
      not Event.password_protected?(event) or
      MapSet.member?(socket.assigns.unlocked_events, event.slug)
  end

  # Signed-in users get to be recognized on their own rows even without the
  # per-device token (ADR-0002). This accepts both identities — either match
  # counts.
  defp joined?(%Event{main_list: main, wait_list: wait}, participant_id, user_id) do
    Enum.any?(main ++ wait, &Attendee.owns?(&1, participant_id, user_id))
  end

  defp confirmed_names(%Event{}, false), do: []

  defp confirmed_names(%Event{main_list: list}, true) do
    list |> Enum.map(&String.trim(&1.name)) |> Enum.reject(&(&1 == ""))
  end

  defp filled_count(%Event{main_list: list}) do
    Enum.count(list, &(String.trim(&1.name) != ""))
  end

  defp when_text(%Event{starts_at: %DateTime{} = starts_at}, _meta) do
    starts_at |> DateTime.add(-3 * 3600, :second) |> Calendar.strftime("%d/%m · %Hh")
  end

  defp when_text(%Event{}, %Meta{date: nil}), do: nil

  defp when_text(%Event{}, %Meta{date: date, time: time}) do
    [Calendar.strftime(date, "%d/%m"), time && Calendar.strftime(time, "%Hh")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp can_join?(socket, %Event{} = event, participant_id, user_id) do
    opts = [
      admin?: socket.assigns.current_admin?,
      organizer?:
        Participant.organizer?(
          %{"organizer_tokens" => socket.assigns[:organizer_tokens] || %{}},
          event
        ),
      participant_id: participant_id,
      current_user_id: user_id
    ]

    unlocked?(socket, event) and
      Policy.can_join?(event, opts) and
      not joined?(event, participant_id, user_id) and
      (not Event.main_full?(event) or event.wait_enabled)
  end

  defp party_room(%Event{wait_enabled: true}), do: Event.max_party_size()

  defp party_room(%Event{main_list: list}) do
    list |> Enum.count(&(String.trim(&1.name) == "")) |> min(Event.max_party_size())
  end

  defp to_home(socket), do: push_navigate(socket, to: ~p"/")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_admin?={@current_admin?}
      page_title={@page_title}
    >
      <:action>
        <div class="space-y-2">
          <button
            :if={@can_join?}
            type="button"
            phx-click={BottomSheet.show("join-sheet")}
            class="w-full rounded-cta bg-ink px-4 py-4 text-[15px] font-bold text-ink-content shadow-cta transition-transform active:scale-[.97] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
          >
            {join_label(@event)}
          </button>

          <.link
            navigate={~p"/r/#{@event.slug}"}
            class="block w-full rounded-cta border-[1.5px] border-ink/15 px-4 py-3.5 text-center text-[15px] font-bold text-ink"
          >
            {if @joined?, do: "Ver a lista", else: "Só ver a lista"}
          </.link>
        </div>
      </:action>
      <div class="mx-auto flex min-h-full max-w-[420px] flex-col">
        <header class="text-center">
          <p class="text-[11px] font-bold uppercase tracking-wide text-accent">Convite recebido</p>
          <h1 class="mt-2 text-[28px] font-extrabold leading-tight tracking-tight">
            {@event.title}
          </h1>
        </header>

        <!-- RN-42: who is in comes before the ask. Deciding whether to go is
             mostly deciding whether your people are going. -->
        <div :if={@confirmed != []} class="mt-5 flex flex-col items-center gap-2">
          <.avatar_stack names={@confirmed} size="md" max={6} ring_class="ring-canvas" />
          <p class="text-[13px] font-semibold text-muted">
            {confirmed_text(@filled, @event.main_capacity)}
          </p>
        </div>

        <p :if={@confirmed == [] and @unlocked?} class="mt-5 text-center text-[13px] text-muted">
          Ninguém entrou ainda. Você pode ser o primeiro.
        </p>

        <section
          :if={@local || @when_text || @amount}
          class="mt-5 rounded-card border border-hairline bg-base-100 px-3.5 shadow-card"
        >
          <.detail_row :if={@local} label="Onde" value={@local} divider={@when_text || @amount} />
          <.detail_row :if={@when_text} label="Quando" value={@when_text} divider={!!@amount} />
          <.detail_row :if={@amount} label="Quanto" value={@amount} divider={false} />
        </section>

        <p :if={not @unlocked?} class="mt-5 text-center text-[13px] text-muted">
          Essa lista pede senha. Abra o rolê pra digitar.
        </p>

        <div class="flex-1" />
      </div>

      <.bottom_sheet
        :if={@can_join?}
        id="join-sheet"
        title={join_label(@event)}
        description={join_description(@event)}
      >
        <form
          id="join-form"
          method="post"
          action={~p"/r/#{@event.slug}/join"}
          phx-hook=".JoinDefaults"
          data-current-user-name={
            (@current_user && Rolezinho.Accounts.User.display_name(@current_user)) || ""
          }
          data-current-user-id={(@current_user && to_string(@current_user.id)) || ""}
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

          <!--
            Same treatment as the join sheet on `EventLive`: opt out of every
            mainstream identity autofill. The `.JoinDefaults` hook below
            prefills from the /me profile via localStorage, which is a
            strictly better UX than a password manager popover over a small
            sheet.
          -->
          <label class="block">
            <span class="mb-1 block text-[11px] font-bold text-muted">Seu nome *</span>
            <input
              type="text"
              name="name"
              data-profile="name"
              required
              maxlength="60"
              autocomplete="off"
              data-1p-ignore="true"
              data-lpignore="true"
              data-bwignore="true"
              data-form-type="other"
              placeholder="Como te chamam no grupo"
              class="w-full rounded-row border border-ink/12 bg-base-100 px-3.5 py-3 text-[13px] font-semibold text-ink outline-none placeholder:font-normal placeholder:text-ink/35 focus:border-accent focus:ring-2 focus:ring-accent/20"
            />
          </label>

          <!-- RN-60/61/62: the questions this organizer chose to ask. Answers
               are scoped to this event and never rendered in the public list.
               Autofill off for the same reason as the name field. -->
          <label :for={field <- @extra_fields} class="mt-3 block">
            <span class="mb-1 block text-[11px] font-bold text-muted">
              {field.label}{if field.required, do: " *"}
            </span>
            <input
              type={field.type}
              name={field.id}
              required={field.required}
              maxlength="200"
              autocomplete="off"
              data-1p-ignore="true"
              data-lpignore="true"
              data-bwignore="true"
              data-form-type="other"
              placeholder={field.placeholder}
              class="w-full rounded-row border border-ink/12 bg-base-100 px-3.5 py-3 text-[13px] font-semibold text-ink outline-none placeholder:font-normal placeholder:text-ink/35 focus:border-accent focus:ring-2 focus:ring-accent/20"
            />
          </label>

          <.form_stepper
            :if={@party_room > 1}
            name="qty"
            label="Quantas pessoas?"
            hint="Você + acompanhantes"
            max={@party_room}
            class="mt-3"
          />

          <button
            type="submit"
            class="mt-3.5 w-full rounded-cta bg-ink px-4 py-4 text-[15px] font-bold text-ink-content shadow-cta transition-transform active:scale-[.97]"
          >
            {join_label(@event)}
          </button>
        </form>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".JoinDefaults">
          const KEY = "rolezinho:profile"

          export default {
            mounted() {
              let profile = {}
              try { profile = JSON.parse(localStorage.getItem(KEY) || "{}") } catch (_) {}

              // ADR-0002: seed the name from the signed-in identity when
              // the device profile has no name yet OR when the previously
              // cached name was seeded from a different user id (account
              // switch on the same browser). Same logic as the matching
              // hook on `EventLive`.
              const fromName = this.el.dataset.currentUserName || ""
              const fromUserId = this.el.dataset.currentUserId || ""
              const stale = fromUserId && profile.seededFromUserId !== fromUserId
              if (fromName && (!profile.name || stale)) {
                profile.name = fromName
                profile.seededFromUserId = fromUserId
                try { localStorage.setItem(KEY, JSON.stringify(profile)) } catch (_) {}
              }

              this.el.querySelectorAll("[data-profile]").forEach((input) => {
                if (!input.value) input.value = profile[input.dataset.profile] || ""
              })
            }
          }
        </script>
      </.bottom_sheet>
    </Layouts.app>
    """
  end

  defp confirmed_text(filled, capacity) when capacity > 0 do
    "#{filled}/#{capacity} confirmados"
  end

  defp confirmed_text(filled, _capacity), do: "#{filled} confirmados"

  defp join_label(%Event{} = event) do
    if Event.main_full?(event), do: "Entrar na espera", else: "Entrar na lista"
  end

  defp join_description(%Event{} = event) do
    if Event.main_full?(event) do
      "A lista principal está cheia. Você entra na espera e sobe se alguém sair."
    end
  end
end
