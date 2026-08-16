defmodule RolezinhoWeb.EventLive do
  @moduledoc """
  Public event page. Renders the header/footer markdown and the two lists,
  and exposes actions for both anonymous visitors and the admin.
  """
  use RolezinhoWeb, :live_view

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.Cash
  alias Rolezinho.Event.Meta
  alias Rolezinho.Event.Policy
  alias Rolezinho.Event.WhatsMarkup
  alias Rolezinho.Events
  alias Rolezinho.Pix
  alias RolezinhoWeb.Components.UI.BottomSheet
  alias RolezinhoWeb.Plugs.Participant

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    visibility = if socket.assigns.current_admin?, do: :any, else: :public

    case Events.find(slug, visibility: visibility) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Rolezinho não encontrado.")
         |> push_navigate(to: ~p"/")}

      event ->
        if connected?(socket), do: Events.subscribe(slug)

        {:ok,
         socket
         |> assign(:show_password_in_share?, false)
         |> assign_event(event)
         |> assign(:new_main_name, "")
         |> assign(:new_wait_name, "")
         |> assign(:editing_main, nil)
         |> assign(:editing_wait, nil)
         |> assign(:confirming_removal, nil)}
    end
  end

  defp assign_event(socket, %Event{} = event) do
    url = url_for(event)
    {meta, stripped_header} = Meta.extract(event.header)

    unlocked? =
      socket.assigns.current_admin? or
        not Event.password_protected?(event) or
        MapSet.member?(socket.assigns.unlocked_events, event.slug)

    # When the visitor hasn't unlocked, hide everything that could reveal
    # sensitive info: the location line, the free-form description block, the
    # PIX QR (which sits inside the description), and the calendar buttons.
    # The Quando (date/time) block on the widget still renders when set — it's
    # a common "save the date" preview.
    display_meta = if unlocked?, do: meta, else: %{meta | local: nil}
    display_header = if unlocked?, do: stripped_header, else: ""

    google_calendar_url =
      if unlocked?, do: Meta.google_url(display_meta, event.title, url), else: nil

    socket
    |> assign(:event, event)
    |> assign_identity(event, unlocked?)
    |> assign(:event_url, url)
    |> assign(:pix, if(unlocked?, do: pix_for(event), else: nil))
    |> assign(:meta, display_meta)
    |> assign(:stripped_header, display_header)
    |> assign(:google_calendar_url, google_calendar_url)
    |> assign(:unlocked?, unlocked?)
    |> assign(:signups_locked?, Event.locked_signups?(event))
    |> assign(:password_protected?, Event.password_protected?(event))
    |> assign(:has_location?, is_binary(meta.local) and meta.local != "")
    |> assign(:page_title, page_title_for(event))
    |> reset_share_toggle_if_disallowed()
    |> assign_shareable_text()
  end

  # Who this browser is *on this event*. The socket carries the session maps
  # (see RolezinhoWeb.Plugs.Participant), and both are scoped by slug so a claim
  # on one event never leaks into another.
  defp assign_identity(socket, %Event{} = event, unlocked?) do
    participant_id = Map.get(socket.assigns[:participants] || %{}, event.slug)

    organizer? =
      Participant.organizer?(
        %{"organizer_tokens" => socket.assigns[:organizer_tokens] || %{}},
        event
      )

    socket
    |> assign(:participant_id, participant_id)
    |> assign(:organizer?, organizer?)
    |> assign(:mine_index, own_row_index(event, participant_id))
    |> assign_cash(event, organizer?)
    |> assign_join_availability(event, participant_id, organizer?, unlocked?)
  end

  # Whether to offer the join action at all. Someone already on the list is not
  # offered it — the waiting list would take them a second time, and a list with
  # the same person twice is a list nobody trusts.
  defp assign_join_availability(socket, %Event{} = event, participant_id, organizer?, unlocked?) do
    opts = [
      admin?: socket.assigns.current_admin?,
      organizer?: organizer?,
      participant_id: participant_id
    ]

    can_join? =
      unlocked? and
        Policy.can_join?(event, opts) and
        is_nil(own_row_index(event, participant_id)) and
        is_nil(own_wait_index(event, participant_id)) and
        (not Event.main_full?(event) or event.wait_enabled)

    # RN-31: promoting is the organizer's call. The button used to render for
    # every visitor, which put a decision that reorders the list in the hands of
    # anyone who opened the page; `handle_event("promote", ...)` still asks the
    # policy, so this only stops offering what would be refused.
    socket
    |> assign(:can_promote?, Policy.can_promote?(event, opts))
    |> assign(:can_join?, can_join?)
    |> assign(:confirmed_names, confirmed_names(event, unlocked?))
    |> assign(:party_room, party_room(event))
    |> assign(:extra_fields, extra_fields(event))
  end

  # The questions the organizer added, beyond the name the form always asks.
  defp extra_fields(%Event{} = event) do
    event |> Events.form_fields() |> Enum.reject(& &1.locked)
  end

  # How large a party this event can still take, which is what the stepper is
  # allowed to reach. With a waiting list the answer is the whole allowance,
  # since the overflow has somewhere to go; without one it is however many slots
  # are actually free.
  defp party_room(%Event{wait_enabled: true}), do: Event.max_party_size()

  defp party_room(%Event{main_list: list}) do
    list
    |> Enum.count(&(String.trim(&1.name) == ""))
    |> min(Event.max_party_size())
  end

  # Names are part of what a password gates, so someone who has not unlocked
  # sees no social proof at all rather than a hidden one.
  defp confirmed_names(%Event{}, false), do: []

  defp confirmed_names(%Event{main_list: list}, true) do
    list
    |> Enum.map(&String.trim(&1.name))
    |> Enum.reject(&(&1 == ""))
  end

  defp own_wait_index(%Event{wait_list: list}, participant_id) do
    case Enum.find_index(list, &Attendee.owned_by?(&1, participant_id)) do
      nil -> nil
      index -> index + 1
    end
  end

  # RN-15, without a screen of its own: the organizer is the one who ends up out
  # of pocket, so the outstanding total belongs on the page they already look at.
  # Nobody else sees it — what the group owes is the organizer's problem to
  # chase, not a scoreboard.
  defp assign_cash(socket, %Event{} = event, organizer?) do
    show? = (organizer? or socket.assigns.current_admin?) and Cash.outstanding?(event)

    socket
    |> assign(:cash, if(show?, do: Cash.summary(event)))
    |> assign(:reminder_text, if(show?, do: Cash.reminder_text(event)))
    # Admin-only, matching `handle_event("clone", ...)`: cloning lands on an
    # /admin edit page, so showing it to a plain organizer would offer a door
    # that closes in their face. A finished event gets the louder "Repetir esse
    # rolê" instead, so this is the button for one still running.
    |> assign(:can_duplicate?, socket.assigns.current_admin? and event.status != :done)
  end

  # The 1-based position of this browser's own row, or nil. Used to highlight it
  # and to decide which check is interactive — everyone else's is read-only.
  defp own_row_index(%Event{main_list: list}, participant_id) do
    case Enum.find_index(list, &Attendee.owned_by?(&1, participant_id)) do
      nil -> nil
      index -> index + 1
    end
  end

  # Mirrors Event.Policy for the template. The handler asks the policy again on
  # every action: this only decides what to draw, and drawing nothing is not a
  # gate.
  defp can_toggle?(_event, %Attendee{name: ""}, _mine?, _admin?, _organizer?), do: false
  defp can_toggle?(_event, _attendee, _mine?, true, _organizer?), do: true
  defp can_toggle?(_event, _attendee, _mine?, _admin?, true), do: true
  defp can_toggle?(_event, _attendee, mine?, _admin?, _organizer?), do: mine?

  defp can_remove?(%Attendee{name: ""}, _mine?, _admin?, _organizer?), do: false
  defp can_remove?(_attendee, _mine?, true, _organizer?), do: true
  defp can_remove?(_attendee, _mine?, _admin?, true), do: true
  defp can_remove?(_attendee, mine?, _admin?, _organizer?), do: mine?

  # RN-22: removal always confirms, naming who is being removed so a mistap in a
  # dense list is caught before it happens.
  defp remove_confirm(true, _name), do: "Sair da lista?"
  defp remove_confirm(false, name), do: "Remover #{name} da lista?"

  defp debt_summary(%{debtors: [_one], missing_cents: missing}) do
    "Falta #{Cash.format_amount(missing)} · 1 pessoa não pagou o Pix."
  end

  defp debt_summary(%{debtors: debtors, missing_cents: missing}) do
    "Faltam #{Cash.format_amount(missing)} · #{length(debtors)} pessoas não pagaram o Pix."
  end

  # How many of the people on the list have declared payment. Returns nil when
  # there is nothing to count — an empty list, or a free event where the check
  # would be reporting on money nobody owes.
  defp paid_summary(%Event{price_cents: cents}) when is_nil(cents) or cents == 0, do: nil

  defp paid_summary(%Event{main_list: list}) do
    people = Enum.filter(list, &(String.trim(&1.name) != ""))

    case {Enum.count(people, & &1.paid), length(people)} do
      {_paid, 0} -> nil
      {paid, total} when paid == total -> "todos pagaram"
      {paid, total} -> "#{paid} de #{total} já pagaram"
    end
  end

  # Shared by every organizer action in the footer group. They sit next to each
  # other, so a divergence between them is visible immediately; keeping one list
  # is what stops that.
  defp organizer_action_class do
    "flex w-full items-center justify-center gap-1.5 rounded-cta border border-hairline " <>
      "bg-surface px-4 py-3 text-[13px] font-bold text-ink transition-all hover:bg-tint " <>
      "active:scale-[.97] focus-visible:outline-2 focus-visible:outline-offset-2 " <>
      "focus-visible:outline-accent"
  end

  defp charge_label(%{debtors: [_one]}), do: "Cobrar no WhatsApp"
  defp charge_label(%{debtors: debtors}), do: "Cobrar os #{length(debtors)} no WhatsApp"

  # The structured field wins over the key recovered from the description: it
  # was typed into a field meant for it, and it accepts every DICT type rather
  # than only the phone shape the regex could recognize.
  defp pix_for(%Event{pix_key: key} = event) when is_binary(key) and key != "" do
    case Pix.classify(key) do
      {:ok, _type, canonical} ->
        %{key: canonical, raw: key, display: Pix.display(key) || key}

      :error ->
        Pix.detect(event.header)
    end
  end

  defp pix_for(%Event{} = event), do: Pix.detect(event.header)

  defp confirmed_summary([_one]), do: "1 pessoa já confirmou"
  defp confirmed_summary(names), do: "#{length(names)} pessoas já confirmaram"

  # Whether this caller can act on every part of the row, which is what makes
  # the swipe gesture worth attaching. An empty slot has nothing to swipe.
  defp manages_row?(%Attendee{name: ""}, _admin?, _organizer?), do: false
  defp manages_row?(_attendee, true, _organizer?), do: true
  defp manages_row?(_attendee, _admin?, organizer?), do: organizer?

  # One row of the list, extracted so it can be rendered bare or wrapped in the
  # swipe container without the markup being written twice.
  attr :attendee, Attendee, required: true
  attr :index, :integer, required: true
  attr :event, Event, required: true
  attr :mine_index, :integer, default: nil
  attr :unlocked?, :boolean, required: true
  attr :current_admin?, :boolean, required: true
  attr :organizer?, :boolean, required: true
  attr :can_join?, :boolean, required: true

  defp event_participant_row(assigns) do
    assigns = assign(assigns, :mine?, assigns.mine_index == assigns.index)

    ~H"""
    <.participant_row
      number={@index}
      name={display_name(@attendee.name, @unlocked?)}
      paid={@attendee.paid}
      highlighted={@mine?}
      divider={@index < length(@event.main_list)}
      paid_click={
        can_toggle?(@event, @attendee, @mine?, @current_admin?, @organizer?) && "toggle_paid_main"
      }
      join_click={@can_join? and BottomSheet.show("join-sheet")}
      empty_label="Vaga livre"
      join_label="Entrar"
      phx-value-index={@index}
    >
      <:actions>
        <button
          :if={@current_admin? and String.trim(@attendee.name) != ""}
          type="button"
          phx-click="start_edit_main"
          phx-value-index={@index}
          class="-mx-1.5 grid size-11 shrink-0 place-items-center text-ink/35"
          aria-label={"Editar #{@attendee.name}"}
        >
          <.icon name="tabler-pencil" class="size-4" />
        </button>
        <button
          :if={can_remove?(@attendee, @mine?, @current_admin?, @organizer?)}
          type="button"
          phx-click="remove_main"
          phx-value-index={@index}
          data-confirm={remove_confirm(@mine?, @attendee.name)}
          class="-ml-3.5 -mr-2 grid size-11 shrink-0 place-items-center text-ink/35"
          aria-label={if @mine?, do: "Sair da lista", else: "Remover #{@attendee.name}"}
        >
          <.icon name="tabler-x" class="size-4" />
        </button>
      </:actions>
    </.participant_row>
    """
  end

  # RN-03: a full main list does not hide the action, it changes what it means.
  # The label has to say which, or someone taps expecting a slot and lands in a
  # queue.
  defp join_label(%Event{} = event) do
    if Event.main_full?(event), do: "Entrar na espera", else: "Entrar na lista"
  end

  defp join_description(%Event{} = event) do
    if Event.main_full?(event) do
      "A lista principal está cheia. Você entra na espera e sobe se alguém sair."
    end
  end

  # Stamps the joining row with whatever identity this browser already holds for
  # the event. A visitor joining for the first time has none yet: a LiveView
  # cannot write to the session, so the id is issued by the join controller
  # (which does hold a conn) and only then travels back here.
  defp join_opts(socket) do
    case socket.assigns[:participant_id] do
      id when is_binary(id) and id != "" -> [participant_id: id]
      _ -> []
    end
  end

  # The options every Policy call needs. Kept in one place so a handler cannot
  # accidentally ask the policy a question with half the context missing.
  defp policy_opts(socket) do
    [
      admin?: socket.assigns.current_admin?,
      organizer?: socket.assigns[:organizer?] || false,
      participant_id: socket.assigns[:participant_id]
    ]
  end

  # If the event's password was removed or the user is no longer unlocked,
  # the toggle must snap back to `false` — both to keep the UI honest and to
  # prevent a stale flag from leaking the password on the next recompute.
  defp reset_share_toggle_if_disallowed(socket) do
    if socket.assigns.unlocked? and socket.assigns.password_protected? do
      socket
    else
      assign(socket, :show_password_in_share?, false)
    end
  end

  defp assign_shareable_text(socket) do
    %{
      event: event,
      event_url: url,
      unlocked?: unlocked?,
      show_password_in_share?: show_pw?
    } = socket.assigns

    include_password? =
      show_pw? and unlocked? and Event.password_protected?(event)

    text =
      Event.to_text(event, url,
        strip_location: not unlocked?,
        hide_description: not unlocked?,
        hide_names: not unlocked?,
        include_password: include_password?
      )

    assign(socket, :shareable_text, text)
  end

  # Page title patterns:
  #
  #   "Vôlei 7/18 (3 na reserva)"      - general case
  #   "Vôlei 7/18"                     - when the wait list is empty/disabled
  #   "Vôlei [Cheio] (5 na reserva)"   - when the main list is full
  #   "Vôlei [Cheio]"                  - full and no reserve
  defp page_title_for(%Event{} = event) do
    filled = filled_count(event.main_list)
    capacity = event.main_capacity

    status =
      if capacity > 0 and filled >= capacity do
        "[Cheio]"
      else
        "#{filled}/#{capacity}"
      end

    wait_count = length(event.wait_list)

    reserve =
      if event.wait_enabled and wait_count > 0 do
        " (#{wait_count} na reserva)"
      else
        ""
      end

    "#{event.title} #{status}#{reserve}"
  end

  # ---------- PubSub ----------

  @impl true
  def handle_info({:updated, %Event{} = event}, socket) do
    {:noreply, assign_event(socket, event)}
  end

  def handle_info({:deleted, _event}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Este rolezinho foi apagado.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_info({:moved, %Event{} = event}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Este rolezinho mudou de endereço.")
     |> push_navigate(to: ~p"/r/#{event.slug}")}
  end

  # ---------- Public actions ----------

  @impl true
  def handle_event("add_to_main", %{"name" => name}, socket) do
    with :ok <- ensure_can_signup(socket),
         {:ok, event} <-
           Events.add_to_main(socket.assigns.event, name, join_opts(socket)) do
      {:noreply,
       socket
       |> assign_event(event)
       |> assign(:new_main_name, "")
       |> put_flash(:info, "Entrou na lista!")}
    else
      {:error, :locked} ->
        {:noreply, put_flash(socket, :error, "Precisa da senha pra entrar nesse rolezinho.")}

      {:error, :signups_locked} ->
        {:noreply,
         put_flash(socket, :error, "Este rolezinho está fechado para novas inscrições.")}

      {:error, :main_full} ->
        {:noreply, put_flash(socket, :error, "Lista principal cheia.")}

      {:error, :empty_name} ->
        {:noreply, put_flash(socket, :error, "Digite um nome.")}
    end
  end

  def handle_event("add_to_wait", %{"name" => name}, socket) do
    with :ok <- ensure_can_signup(socket),
         {:ok, event} <-
           Events.add_to_wait(socket.assigns.event, name, join_opts(socket)) do
      {:noreply,
       socket
       |> assign_event(event)
       |> assign(:new_wait_name, "")
       |> put_flash(:info, "Entrou na reserva!")}
    else
      {:error, :locked} ->
        {:noreply, put_flash(socket, :error, "Precisa da senha pra entrar nesse rolezinho.")}

      {:error, :signups_locked} ->
        {:noreply,
         put_flash(socket, :error, "Este rolezinho está fechado para novas inscrições.")}

      {:error, :empty_name} ->
        {:noreply, put_flash(socket, :error, "Digite um nome.")}

      {:error, :wait_disabled} ->
        {:noreply, put_flash(socket, :error, "Este rolezinho não tem lista de reserva.")}
    end
  end

  # RN-31. `ensure_can_signup` only reports whether the password was entered, so
  # it does not answer this: promoting reorders who is in the rolê, and any
  # unlocked visitor could send this message without ever seeing a button.
  def handle_event("promote", %{"index" => index}, socket) do
    with :ok <- ensure_can_signup(socket),
         :ok <- ensure_can_promote(socket),
         {:ok, event} <- Events.promote(socket.assigns.event, String.to_integer(index)) do
      {:noreply,
       socket
       |> assign_event(event)
       |> put_flash(:info, "Promovido pra lista principal!")}
    else
      {:error, :locked} ->
        {:noreply, put_flash(socket, :error, "Precisa da senha pra mexer nesse rolezinho.")}

      {:error, :signups_locked} ->
        {:noreply, put_flash(socket, :error, "Rolezinho fechado para novas inscrições.")}

      {:error, :main_full} ->
        {:noreply, put_flash(socket, :error, "A lista principal está cheia.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Só quem organiza pode promover.")}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  # ---------- Admin actions ----------

  # RN-12/RN-13: the organizer marks anyone; a participant marks only their own
  # row. The check is here rather than in the template because the button being
  # absent does not stop the message from arriving.
  def handle_event("toggle_paid_main", %{"index" => index}, socket) do
    authorize_row(socket, :main, index, &Policy.can_toggle_paid?/3, fn event, position ->
      Events.toggle_paid_main(event, position)
    end)
  end

  # The swipe gesture cannot carry a data-confirm, so it asks first and the
  # confirmation sheet performs the removal (RN-22). Reaching it does not
  # authorize anything: remove_main still consults the policy.
  def handle_event("ask_remove_main", %{"id" => index}, socket) do
    with {:ok, position} <- parse_position(index),
         %Attendee{} = attendee <- fetch_row(socket.assigns.event, :main, position) do
      {:noreply, assign(socket, :confirming_removal, %{index: position, name: attendee.name})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_remove", _params, socket) do
    {:noreply, assign(socket, :confirming_removal, nil)}
  end

  # RN-21: a participant removes only themselves; the organizer removes anyone.
  def handle_event("remove_main", %{"index" => index}, socket) do
    authorize_row(socket, :main, index, &Policy.can_remove?/3, fn event, position ->
      Events.remove_main(event, position)
    end)
  end

  def handle_event("remove_wait", %{"index" => index}, socket) do
    authorize_row(socket, :wait, index, &Policy.can_remove?/3, fn event, position ->
      Events.remove_wait(event, position)
    end)
  end

  def handle_event("start_edit_main", %{"index" => index}, socket) do
    require_admin!(socket)
    {:noreply, assign(socket, :editing_main, String.to_integer(index))}
  end

  def handle_event("start_edit_wait", %{"index" => index}, socket) do
    require_admin!(socket)
    {:noreply, assign(socket, :editing_wait, String.to_integer(index))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_main, nil) |> assign(:editing_wait, nil)}
  end

  def handle_event("rename_main", %{"index" => index, "name" => name}, socket) do
    require_admin!(socket)
    {:ok, event} = Events.rename_main(socket.assigns.event, String.to_integer(index), name)

    {:noreply,
     socket
     |> assign_event(event)
     |> assign(:editing_main, nil)}
  end

  def handle_event("rename_wait", %{"index" => index, "name" => name}, socket) do
    require_admin!(socket)
    {:ok, event} = Events.rename_wait(socket.assigns.event, String.to_integer(index), name)

    {:noreply,
     socket
     |> assign_event(event)
     |> assign(:editing_wait, nil)}
  end

  def handle_event("grow_main", _params, socket) do
    require_admin!(socket)
    new_size = socket.assigns.event.main_capacity + 1
    {:ok, event} = Events.resize_main(socket.assigns.event, new_size)
    {:noreply, assign_event(socket, event)}
  end

  def handle_event("shrink_main", _params, socket) do
    require_admin!(socket)
    new_size = socket.assigns.event.main_capacity - 1
    {:ok, event} = Events.resize_main(socket.assigns.event, max(new_size, 1))
    {:noreply, assign_event(socket, event)}
  end

  def handle_event("clone", _params, socket) do
    require_admin!(socket)

    case Events.clone(socket.assigns.event) do
      {:ok, clone} ->
        {:noreply,
         socket
         |> put_flash(:info, "Rolezinho clonado. Ajuste e salve.")
         |> push_navigate(to: ~p"/admin/r/#{clone.slug}/edit")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Não deu pra clonar: #{inspect(reason)}")}
    end
  end

  # ---------- Share options ----------

  def handle_event("toggle_share_password", _params, socket) do
    if allowed_to_toggle_share_password?(socket) do
      show? = not socket.assigns.show_password_in_share?

      {:noreply,
       socket
       |> assign(:show_password_in_share?, show?)
       |> assign_shareable_text()}
    else
      # Silently drop unauthorized toggles so a crafted socket message can't
      # even leak that the flag exists on this session.
      {:noreply, socket}
    end
  end

  # ---------- Input tracking ----------

  def handle_event("update_new_main_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_main_name, name)}
  end

  def handle_event("update_new_wait_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_wait_name, name)}
  end

  # Ensures the current visitor may sign up: admins always can, otherwise the
  # slug must be in the unlocked-set (or the event must have no password).
  defp ensure_can_signup(socket) do
    if socket.assigns.unlocked?, do: :ok, else: {:error, :locked}
  end

  defp ensure_can_promote(socket) do
    if socket.assigns.can_promote?, do: :ok, else: {:error, :forbidden}
  end

  # Server-side gate for the "include password in share text" toggle. The
  # checkbox is only rendered for admins/unlocked users on password-protected
  # events, but we re-check here so a hacker crafting a raw socket message
  # can't flip the flag and read the password from `data-text`.
  defp allowed_to_toggle_share_password?(socket) do
    socket.assigns.unlocked? and Event.password_protected?(socket.assigns.event)
  end

  defp require_admin!(socket) do
    unless socket.assigns.current_admin? do
      raise "unauthorized"
    end

    :ok
  end

  # Resolves a row from a client-supplied index, asks the policy whether this
  # caller may act on it, and only then runs the operation.
  #
  # The index arrives over the socket, so it is hostile input twice over: it can
  # point outside the list, and it can point at somebody else's row. Both are
  # rejected here — silently, because a caller that fabricated the message is not
  # owed an explanation, and a stale index from a list that changed underneath is
  # not worth an error toast.
  defp authorize_row(socket, list, raw_index, allowed?, operation) do
    event = socket.assigns.event

    with {:ok, position} <- parse_position(raw_index),
         %Attendee{} = attendee <- fetch_row(event, list, position),
         true <- allowed?.(event, attendee, policy_opts(socket)),
         {:ok, updated} <- operation.(event, position) do
      # Any row action settles whatever confirmation was pending: leaving the
      # sheet open over a list that just changed would point it at a row that
      # may no longer be the one it named.
      {:noreply, socket |> assign(:confirming_removal, nil) |> assign_event(updated)}
    else
      _ -> {:noreply, socket}
    end
  end

  defp parse_position(index) when is_integer(index), do: {:ok, index}

  defp parse_position(index) when is_binary(index) do
    case Integer.parse(index) do
      {position, ""} when position > 0 -> {:ok, position}
      _ -> :error
    end
  end

  defp parse_position(_), do: :error

  # Positions are 1-based, and a row only exists if someone is in it: an empty
  # slot has nothing to pay for and nobody to remove.
  defp fetch_row(%Event{} = event, list, position) do
    case event |> list_for(list) |> Enum.at(position - 1) do
      %Attendee{name: name} = attendee when name != "" -> attendee
      _ -> nil
    end
  end

  defp list_for(%Event{main_list: list}, :main), do: list
  defp list_for(%Event{wait_list: list}, :wait), do: list

  # ---------- Rendering ----------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin?={@current_admin?} page_title={@page_title}>
      <:action :if={@can_join?}>
        <button
          type="button"
          phx-click={BottomSheet.show("join-sheet")}
          class="w-full rounded-cta bg-ink px-4 py-4 text-[15px] font-bold text-ink-content shadow-cta transition-transform active:scale-[.97] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        >
          {join_label(@event)}
        </button>
      </:action>

      <article
        id="role-card"
        class="space-y-8"
        phx-remove={
          JS.dispatch("phx:start-view-transition",
            to: "#role-card",
            detail: %{transition_name: "role-slide-out-left", type: "page"}
          )
        }
      >
        <header class="space-y-3">
          <div class="flex items-center gap-2 text-xs text-base-content/50">
            <.link navigate={~p"/"} class="hover:text-base-content">← Rolezinhos</.link>
            <span>·</span>
            <span>/r/{@event.slug}</span>
            <span
              :if={@event.status == :hidden}
              class="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium bg-warning/15 text-warning"
            >Oculto</span>
            <span
              :if={@event.status == :done}
              class="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium bg-base-300 text-base-content"
            >Concluído</span>
            <span
              :if={@signups_locked?}
              class="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium bg-info/15 text-info"
            >Só pagamentos</span>
            <span
              :if={@password_protected?}
              class="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium border border-base-300"
            >Com senha</span>
          </div>

          <!-- Screen actions belong beside the title. Loose between two cards
               they read as an orphan with no owner. -->
          <div class="flex items-start justify-between gap-3">
            <h1
              class="min-w-0 flex-1 text-2xl font-extrabold tracking-tight"
              style="view-transition-name: match-role-title;"
            >
              {@event.title}
            </h1>

            <div class="flex shrink-0 items-center gap-1.5">
              <button
                type="button"
                phx-click={BottomSheet.show("share-sheet")}
                class="grid size-11 place-items-center rounded-full bg-ink/[0.06] text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
                aria-label="Compartilhar a lista"
              >
                <.icon name="tabler-share" class="size-[18px]" />
              </button>
              <.link
                :if={@current_admin?}
                navigate={~p"/admin/r/#{@event.slug}/edit"}
                class="grid size-11 place-items-center rounded-full bg-ink/[0.06] text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
                aria-label="Editar o rolê"
              >
                <.icon name="tabler-pencil" class="size-[18px]" />
              </.link>
            </div>
          </div>

          <.payments_only_notice :if={@signups_locked?} />

          <.unlock_panel
            :if={@password_protected? and not @unlocked?}
            slug={@event.slug}
            has_location?={@has_location?}
          />

          <!-- One card, and the description under it. The four-way cond this
               replaces existed only to pair two panels that are now one. -->
          <.event_details
            :if={Meta.any?(@meta) or @pix}
            meta={@meta}
            slug={@event.slug}
            google_calendar_url={@google_calendar_url}
            pix={@pix}
            amount={Cash.format_amount(@event.price_cents)}
          />

          <!-- The organizer's own words, in a card of their own. Loose under the
               details it read as a stray paragraph belonging to nothing; labelled,
               it is clear whose text this is and why it is on the page. -->
          <section
            :if={@stripped_header != ""}
            class="rounded-card border border-hairline bg-base-100 p-4"
          >
            <h2 class="text-[10px] font-semibold uppercase tracking-wide text-muted">
              Recado do organizador
            </h2>
            <div class="prose prose-sm mt-1.5 max-w-none leading-relaxed prose-p:my-1.5 prose-p:text-[13px]">
              {raw(render_markdown(@stripped_header))}
            </div>
          </section>
        </header>

        <!-- RN-52: repeating is the natural next move once a rolê is over, and
             it is the moment somebody looks for it. An unlabelled duplicate icon
             in a toolbar is not something anyone goes hunting for, so on a
             finished event it becomes the primary action, named for what it
             does rather than for the operation behind it. -->
        <button
          :if={@current_admin? and @event.status == :done}
          type="button"
          phx-click="clone"
          class="flex w-full items-center justify-center gap-2 rounded-cta bg-ink px-4 py-4 text-[15px] font-bold text-ink-content shadow-cta transition-transform active:scale-[.97] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        >
          <.icon name="tabler-repeat" class="size-[18px]" /> Repetir esse rolê
        </button>

        <section class="rounded-2xl border border-base-300 bg-base-100 p-5">
          <div class="flex items-center justify-between mb-4 gap-3 flex-wrap">
            <div>
              <h2 class="text-xl font-semibold">Lista principal</h2>
              <!-- RN-14 says a check cannot stand alone, and this is what says
                   what it means: the count and the marks tell the same story, so
                   reading one explains the other. A legend of circle-plus-label
                   pairs said it in the grammar of a filter, which is why it read
                   as two things to choose between. -->
              <p class="text-sm text-base-content/60">
                {filled_count(@event.main_list)} / {@event.main_capacity} vagas<span :if={
                  @unlocked? and paid_summary(@event)
                }>
                  · {paid_summary(@event)}
                </span>
              </p>
            </div>
            <div :if={@current_admin?} class="inline-flex -space-x-px">
              <button
                type="button"
                phx-click="shrink_main"
                disabled={@event.main_capacity <= max(filled_count(@event.main_list), 1)}
                class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:pointer-events-none px-4 py-2 text-sm px-3 py-1.5 rounded-none first:rounded-l-md last:rounded-r-md"
                title="Diminuir uma vaga"
              >
                <.icon name="tabler-minus" class="size-4" />
              </button>
              <span class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:pointer-events-none px-4 py-2 text-sm px-3 py-1.5 rounded-none first:rounded-l-md last:rounded-r-md pointer-events-none">Vagas: {@event.main_capacity}</span>
              <button
                type="button"
                phx-click="grow_main"
                class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:pointer-events-none px-4 py-2 text-sm px-3 py-1.5 rounded-none first:rounded-l-md last:rounded-r-md"
                title="Adicionar uma vaga"
              >
                <.icon name="tabler-plus" class="size-4" />
              </button>
            </div>
          </div>

          <.coachmark :if={@mine_index} seen_key="paid-check" class="mb-2">
            Toque no check quando fizer o Pix. Só você marca o seu.
          </.coachmark>

          <ol class="overflow-hidden rounded-row border border-hairline bg-base-100">
            <li :for={{%Attendee{} = att, i} <- Enum.with_index(@event.main_list, 1)}>
              <%= if @editing_main == i do %>
                <form
                  phx-submit="rename_main"
                  phx-value-index={i}
                  class="flex items-center gap-2 border-b border-ink/6 px-3.5 py-2.5"
                >
                  <input
                    type="text"
                    name="name"
                    value={att.name}
                    class={[field_class(), "flex-1"]}
                    autofocus
                  />
                  <button
                    type="submit"
                    class="shrink-0 rounded-lg bg-ink px-2.5 py-1.5 text-[11px] font-bold text-ink-content"
                  >
                    Salvar
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_edit"
                    class="shrink-0 px-2 py-1.5 text-[11px] font-bold text-muted"
                  >
                    Cancelar
                  </button>
                </form>
              <% else %>
                <!-- An organizer going down eighteen rows gets the gesture as an
                     accelerator. It is never the only way in: the same actions
                     stay in the row as buttons, which is what keyboard and
                     screen-reader users reach. -->
                <.swipe_actions
                  :if={manages_row?(att, @current_admin?, @organizer?)}
                  value={to_string(i)}
                >
                  <:action label="Pago" tone="accent" on_click="toggle_paid_main" />
                  <:action label="Tirar" tone="danger" on_click="ask_remove_main" />
                  <.event_participant_row
                    attendee={att}
                    index={i}
                    event={@event}
                    mine_index={@mine_index}
                    unlocked?={@unlocked?}
                    current_admin?={@current_admin?}
                    organizer?={@organizer?}
                    can_join?={@can_join?}
                  />
                </.swipe_actions>

                <.event_participant_row
                  :if={not manages_row?(att, @current_admin?, @organizer?)}
                  attendee={att}
                  index={i}
                  event={@event}
                  mine_index={@mine_index}
                  unlocked?={@unlocked?}
                  current_admin?={@current_admin?}
                  organizer?={@organizer?}
                  can_join?={@can_join?}
                />
              <% end %>
            </li>
          </ol>

          <p
            :if={not @unlocked? and not @signups_locked?}
            class="mt-4 text-sm text-base-content/60"
          >
            Digite a senha acima pra entrar na lista.
          </p>

          <p :if={@signups_locked?} class="mt-4 text-sm text-base-content/60">
            Novas inscrições estão pausadas. Marcados com <span class="text-success">✅</span> pagaram.
          </p>

          <p
            :if={Event.main_full?(@event) and not @event.wait_enabled and not @signups_locked?}
            class="mt-4 text-sm text-warning"
          >
            A lista principal está cheia.
          </p>
        </section>

        <section :if={@event.wait_enabled} class="rounded-2xl border border-base-300 bg-base-100 p-5">
          <div class="mb-4">
            <h2 class="text-xl font-semibold">Lista de reserva</h2>
            <p
              :if={@event.wait_intro not in ["Lista de reserva", ""]}
              class="text-sm text-base-content/60"
            >
              {@event.wait_intro}
            </p>
            <p class="text-sm text-base-content/60">
              {length(@event.wait_list)} pessoa(s) na reserva
            </p>
          </div>

          <ol :if={@event.wait_list != []} class="space-y-2">
            <li
              :for={{%Attendee{} = att, i} <- Enum.with_index(@event.wait_list, 1)}
              class="flex items-center gap-3 rounded-xl bg-base-200 px-3 py-2"
            >
              <span class="text-sm font-mono w-8 text-right text-base-content/50">{i}.</span>

              <%= cond do %>
                <% @editing_wait == i -> %>
                  <form
                    phx-submit="rename_wait"
                    phx-value-index={i}
                    class="flex-1 flex items-center gap-2"
                  >
                    <input
                      type="text"
                      name="name"
                      value={att.name}
                      class={[field_class(), "px-2 py-1 flex-1"]}
                      autofocus
                    />
                    <button
                      type="submit"
                      class="rounded-lg bg-ink px-2.5 py-1.5 text-[11px] font-bold text-ink-content"
                    >Salvar</button>
                    <button
                      type="button"
                      phx-click="cancel_edit"
                      class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:pointer-events-none px-4 py-2 text-sm px-3 py-1.5 hover:bg-base-200"
                    >Cancelar</button>
                  </form>
                <% true -> %>
                  <span class={[
                    "flex-1 truncate font-medium",
                    not @unlocked? && "tracking-widest text-base-content/60"
                  ]}>
                    {display_name(att.name, @unlocked?)}
                  </span>
              <% end %>

              <div class="flex items-center gap-1 shrink-0">
                <!-- No payment check here: somebody on the queue has not got a
                     place yet, so they owe nothing. Money is settled on the main
                     list, once they are actually in.

                     Kept visible while the main list is full, only disabled: the
                     queue exists precisely because it is full, so hiding the one
                     action the queue has at that moment left the row with nothing
                     to do.

                     Outlined while unavailable rather than a faded solid: a full
                     main list is the queue's ordinary state, so every row would
                     have carried a greyed-out slab and the whole card read as
                     broken. This reads as waiting for a slot instead. -->
                <button
                  :if={@can_promote? and @editing_wait != i}
                  type="button"
                  phx-click="promote"
                  phx-value-index={i}
                  disabled={Event.main_full?(@event)}
                  class={[
                    "rounded-lg px-2.5 py-1.5 text-[10px] font-bold",
                    if(Event.main_full?(@event),
                      do: "cursor-not-allowed border border-hairline text-muted",
                      else: "bg-ink text-ink-content"
                    )
                  ]}
                  title={
                    if Event.main_full?(@event),
                      do: "A lista principal está cheia",
                      else: "Promover para a lista principal"
                  }
                >
                  <.icon name="tabler-arrow-up" class="size-3.5" /> Promover
                </button>
                <button
                  :if={@current_admin? and @editing_wait != i}
                  type="button"
                  phx-click="start_edit_wait"
                  phx-value-index={i}
                  class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:pointer-events-none px-4 py-2 text-sm px-2 py-1 text-xs hover:bg-base-200"
                  title="Editar nome"
                >
                  <.icon name="tabler-pencil" class="size-3.5" />
                </button>
                <button
                  :if={@current_admin? and @editing_wait != i}
                  type="button"
                  phx-click="remove_wait"
                  phx-value-index={i}
                  data-confirm="Remover da reserva?"
                  class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:pointer-events-none px-4 py-2 text-sm px-2 py-1 text-xs hover:bg-base-200 text-error"
                  title="Remover"
                >
                  <.icon name="tabler-x" class="size-3.5" />
                </button>
              </div>
            </li>
          </ol>

          <div :if={@unlocked? and not @signups_locked?} class="mt-4">
            <form
              phx-submit="add_to_wait"
              phx-change="update_new_wait_name"
              class="flex gap-2 flex-wrap"
              id="add-wait-form"
            >
              <input
                type="text"
                name="name"
                value={@new_wait_name}
                placeholder="Seu nome"
                class={[field_class(), "flex-1 min-w-0"]}
                required
              />
              <button
                type="submit"
                class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:pointer-events-none px-4 py-2 text-sm border border-base-300 hover:bg-base-200"
              >Entrar na reserva</button>
            </form>
          </div>

          <p
            :if={not @unlocked? and not @signups_locked?}
            class="mt-4 text-sm text-base-content/60"
          >
            Digite a senha acima pra entrar na reserva.
          </p>
        </section>

        <section :if={@event.footer != ""} class="rounded-2xl border border-base-300 bg-base-100 p-5">
          <div class="prose prose-sm sm:prose-base max-w-none">
            {raw(render_markdown(@event.footer))}
          </div>
        </section>
        <!-- Deliberately tighter than the article's 32px rhythm, which separates
             independent cards. This is not a third card: it reports on the lists
             above and acts on them, so it reads as their footer. At a full 32px
             it floated as its own unrelated section. `!mt-4` because `space-y-8`
             on the parent sets the margin on every sibling.

             The banner states a condition and the button acts on it, so they
             stay a pair — but at 8px the button read as the banner's own
             footer. 12px keeps the causal link legible while giving the button
             its own edge as a tap target.

             Outlined rather than solid: the pinned action below is already the
             filled one, and two black buttons stacked read as two primary
             actions competing. Charging is the organizer's errand; joining is
             what the visitor came for, so joining keeps the weight.

             `hairline` is the project's border token, so this matches the cards
             around it. No surface in the palette reaches 3:1 against the canvas,
             so the outline is not carrying identification on its own — the
             label, the WhatsApp mark, and the link role do that, and focus draws
             a full accent ring. -->
        <div :if={not is_nil(@cash) or @can_duplicate?} class="!mt-4 space-y-3">
          <.alert_banner :if={@cash} tone="warn">{debt_summary(@cash)}</.alert_banner>
          <a
            :if={not is_nil(@cash) and not is_nil(@reminder_text)}
            href={"https://wa.me/?text=" <> URI.encode(@reminder_text)}
            target="_blank"
            rel="noopener"
            class={organizer_action_class()}
          >
            <.icon name="tabler-brand-whatsapp" class="size-4" />
            {charge_label(@cash)}
          </a>
          <button
            :if={@can_duplicate?}
            type="button"
            phx-click="clone"
            data-confirm="Criar uma cópia deste rolezinho?"
            class={organizer_action_class()}
          >
            <.icon name="tabler-copy" class="size-4" /> Duplicar pra outra data
          </button>
        </div>
      </article>

      <!-- RN-22: removal always confirms, naming who is going. The destructive
           action sits on the right, in the danger tone, so the safe one is
           where a thumb lands by default. -->
      <.bottom_sheet
        :if={@confirming_removal}
        id="remove-sheet"
        open
        title={"Remover #{@confirming_removal.name} da lista?"}
        description="Quem estiver na espera pode ser promovido pra vaga."
        on_cancel={JS.push("cancel_remove")}
      >
        <:actions>
          <button
            type="button"
            phx-click="cancel_remove"
            class="flex-1 rounded-row bg-ink/[0.06] py-3 text-xs font-bold text-ink"
          >
            Cancelar
          </button>
          <button
            type="button"
            phx-click="remove_main"
            phx-value-index={@confirming_removal.index}
            class="flex-1 rounded-row bg-danger py-3 text-xs font-bold text-danger-content"
          >
            Remover
          </button>
        </:actions>
      </.bottom_sheet>

      <!-- RN-40: the group chat is the channel, so the product's job is to hand
           back a block of text somebody can paste there. The preview shows what
           will actually be pasted, because a share button that copies something
           unseen gets pasted once and never again. -->
      <.bottom_sheet id="share-sheet" title="Mandar no grupo">
        <label
          :if={@password_protected? and @unlocked?}
          class="mb-3 flex items-center gap-2.5 rounded-row bg-tint px-3 py-2.5"
        >
          <input
            id="share-password-toggle"
            type="checkbox"
            class={checkbox_class()}
            phx-click="toggle_share_password"
            checked={@show_password_in_share?}
          />
          <span class="text-xs font-semibold">Incluir a senha no texto</span>
        </label>

        <.share_preview text={@shareable_text} />

        <:actions>
          <button
            id="copy-btn"
            type="button"
            phx-hook=".CopyText"
            data-text={@shareable_text}
            data-copied-label="Copiado!"
            class="flex-1 rounded-row bg-ink/[0.06] py-3 text-xs font-bold text-ink"
          >
            Copiar
          </button>
          <button
            id="share-btn"
            type="button"
            phx-hook=".ShareEvent"
            data-title={@event.title}
            data-text={@shareable_text}
            data-url={@event_url}
            class="flex-1 rounded-row bg-ink py-3 text-xs font-bold text-ink-content"
          >
            Compartilhar
          </button>
        </:actions>
      </.bottom_sheet>

      <!-- Rendered only when joining is actually allowed. A sheet that exists
           but is hidden is markup someone can still submit, and the gate has to
           be the server's decision rather than a CSS class. -->
      <.bottom_sheet
        :if={@can_join?}
        id="join-sheet"
        title={join_label(@event)}
        description={join_description(@event)}
      >
        <!-- RN-42: who is already in, above the action. Deciding whether to go
             is mostly deciding whether your people are going, so the names come
             before the form rather than after it. -->
        <div :if={@confirmed_names != []} class="mb-3.5 flex items-center gap-2.5">
          <.avatar_stack names={@confirmed_names} size="sm" max={5} ring_class="ring-white" />
          <span class="text-[11px] font-semibold text-muted">{confirmed_summary(@confirmed_names)}</span>
        </div>

        <form
          id="join-form"
          method="post"
          action={~p"/r/#{@event.slug}/join"}
          phx-hook=".JoinDefaults"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />

          <label class="block">
            <span class="mb-1 block text-[11px] font-bold text-muted">Seu nome *</span>
            <input
              type="text"
              name="name"
              data-profile="name"
              required
              maxlength="60"
              autocomplete="name"
              placeholder="Como te chamam no grupo"
              class="w-full rounded-row border border-ink/12 bg-base-100 px-3.5 py-3 text-[13px] font-semibold text-ink outline-none placeholder:font-normal placeholder:text-ink/35 focus:border-accent focus:ring-2 focus:ring-accent/20"
            />
          </label>

          <!-- RN-04: each companion becomes a row of their own, so the count
               here decides how many rows are created, not a "+2" suffix on one
               of them. -->
          <!-- RN-60/61/62: the questions this organizer chose to ask. Answers
               are scoped to this event and never rendered in the public list. -->
          <label :for={field <- @extra_fields} class="mt-3 block">
            <span class="mb-1 block text-[11px] font-bold text-muted">
              {field.label}{if field.required, do: " *"}
            </span>
            <input
              type={field.type}
              name={field.id}
              required={field.required}
              maxlength="200"
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
          export default {
            mounted() {
              // Someone who has filled in their name once should not type it
              // again in every list they join.
              let profile = {}
              try { profile = JSON.parse(localStorage.getItem("rolezinho:profile") || "{}") } catch (_) {}

              this.el.querySelectorAll("[data-profile]").forEach((input) => {
                if (!input.value) input.value = profile[input.dataset.profile] || ""
              })
            }
          }
        </script>
      </.bottom_sheet>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
        export default {
          mounted() {
            this.el.addEventListener("click", async () => {
              const text = this.el.dataset.text || ""
              const done = this.el.dataset.copiedLabel || "Copiado!"
              try {
                await navigator.clipboard.writeText(text)
                this.flash(done)
              } catch (e) {
                // Fallback for very old browsers
                const ta = document.createElement("textarea")
                ta.value = text
                document.body.appendChild(ta)
                ta.select()
                try { document.execCommand("copy"); this.flash(done) } catch (_) { this.flash("Não deu pra copiar") }
                document.body.removeChild(ta)
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

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ShareEvent">
        export default {
          mounted() {
            this.el.addEventListener("click", async () => {
              const title = this.el.dataset.title || "Rolezinho"
              const text = this.el.dataset.text || ""
              const url = this.el.dataset.url || location.href
              if (navigator.share) {
                try {
                  await navigator.share({ title, text, url })
                } catch (_) {}
              } else {
                try {
                  await navigator.clipboard.writeText(text + "\n" + url)
                  const original = this.el.innerHTML
                  this.el.innerText = "Link copiado!"
                  setTimeout(() => { this.el.innerHTML = original }, 1500)
                } catch (_) {}
              }
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp filled_count(list), do: Enum.count(list, fn a -> String.trim(a.name) != "" end)

  # Attendee name shown in the list rows. Password-protected events hide names
  # from visitors who haven't unlocked the session yet.
  defp display_name(name, true = _unlocked?), do: name
  defp display_name("", _), do: ""
  defp display_name(_name, false = _unlocked?), do: Event.hidden_name_placeholder()

  defp url_for(%Event{slug: slug}) do
    RolezinhoWeb.Endpoint.url() <> "/r/" <> slug
  end

  # ---------- Payments-only banner + unlock panel ----------

  defp payments_only_notice(assigns) do
    ~H"""
    <section class="rounded-2xl border border-info/40 bg-info/10 p-4 sm:p-5">
      <div class="flex items-start gap-3">
        <.icon name="tabler-cash-banknote" class="size-5 text-info shrink-0 mt-0.5" />
        <div class="space-y-1">
          <p class="font-semibold">Rolezinho fechado, só pagamentos.</p>
          <p class="text-sm text-base-content/80">
            Quem ainda não tem o <span class="text-success font-semibold">✅</span>
            precisa pagar pra confirmar a vaga. Não dá pra entrar em novas listas
            enquanto o rolezinho estiver nesse estado.
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :slug, :string, required: true
  attr :has_location?, :boolean, required: true

  # The gate someone lands on when a shared link reaches them (RN-41). It is a
  # whole screen rather than a warning strip because it is the only thing to do
  # here: everything else on the page is deliberately withheld until the password
  # is right, on the server.
  defp unlock_panel(assigns) do
    ~H"""
    <section class="mx-auto max-w-[420px] px-2 py-6 text-center">
      <div class="mx-auto grid size-16 place-items-center rounded-[22px] bg-ink">
        <.icon name="tabler-lock" class="size-7 text-accent" />
      </div>

      <p class="mt-5 text-[11px] font-bold uppercase tracking-wide text-accent">
        Convite recebido
      </p>
      <h2 class="mt-2 text-2xl font-extrabold leading-tight tracking-tight">
        Essa lista é<br />protegida por senha
      </h2>
      <p class="mt-3 text-sm leading-relaxed text-muted">
        <%= if @has_location? do %>
          Digite a senha que veio junto com o link pra ver o local, os nomes e entrar na lista.
        <% else %>
          Digite a senha que veio junto com o link pra ver os nomes e entrar na lista.
        <% end %>
      </p>

      <form
        method="post"
        action={~p"/r/#{@slug}/unlock"}
        id={"unlock-form-" <> @slug}
        class="mt-6 rounded-[20px] border border-hairline bg-base-100 p-4 text-left shadow-card"
      >
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <label class="block">
          <span class="text-[11px] font-bold uppercase tracking-wide text-muted">
            Senha da lista
          </span>
          <input
            type="password"
            name="password"
            placeholder="ex: VOLEI25"
            autocomplete="off"
            autocapitalize="characters"
            required
            class="mt-2 w-full border-0 border-b-2 border-ink/12 bg-transparent px-0 py-1.5 text-xl font-extrabold uppercase tracking-[2px] text-ink outline-none placeholder:tracking-normal placeholder:text-ink/25 focus:border-accent"
          />
        </label>

        <button
          type="submit"
          class="mt-4 w-full rounded-cta bg-ink px-4 py-4 text-[15px] font-bold text-ink-content shadow-cta transition-transform active:scale-[.97] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        >
          Ver o rolê
        </button>
      </form>

      <p class="mt-3.5 text-xs text-muted">
        Não tem a senha? Pede pra quem te chamou.
      </p>
    </section>
    """
  end

  # ---------- Event details card ----------

  # Where, when and how much — one card, one vocabulary. This used to be three
  # stacked containers in three different styles (a tinted panel with a coloured
  # border, two loose tiles, an orange link floating between them), which is what
  # made the block read as a different product from the list below it.
  #
  # Facts are rows, not tiles: a row carries a label and a value at reading size,
  # and stacking them lets the eye run down one edge. Money gets the tile,
  # because the amount and the key are the two things somebody acts on.
  attr :meta, :map, required: true
  attr :slug, :string, required: true
  attr :google_calendar_url, :string, required: true, doc: "nil when no date is set"
  attr :pix, :map, default: nil
  attr :amount, :string, default: nil

  defp event_details(assigns) do
    ~H"""
    <section class="overflow-hidden rounded-card border border-hairline bg-base-100">
      <div :if={@meta.date || @meta.time || @meta.local} class="px-3.5">
        <.detail_row
          :if={@meta.date || @meta.time}
          label="Quando"
          value={Meta.format_when(@meta)}
          divider={!!@meta.local}
        />
        <.detail_row :if={@meta.local} label="Onde" value={@meta.local} divider={false} />
      </div>

      <div :if={@amount || @pix} class="space-y-2 px-3.5 pb-3.5 pt-1">
        <.info_tile :if={@amount} label="Valor" value={@amount} />
        <.info_tile
          :if={@pix}
          label="Chave Pix"
          value={@pix.display}
          action="Copiar"
          id={"copy-pix-" <> @slug}
          phx-hook=".CopyText"
          data-text={@pix.key}
          data-copied-label="Copiado!"
        />
      </div>

      <!-- Secondary by construction: adding to a calendar and opening the QR are
           things someone does once, so they sit on the tinted footer of the card
           rather than competing with the list. -->
      <div
        :if={@google_calendar_url || @pix}
        class="flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-hairline bg-surface px-3.5 py-3"
      >
        <.link
          :if={@pix}
          navigate={~p"/r/#{@slug}/pagamento"}
          class="inline-flex items-center gap-1.5 text-[11px] font-bold text-accent"
        >
          <.icon name="tabler-qrcode" class="size-4" /> Ver o QR Code
        </.link>
        <a
          :if={@google_calendar_url}
          href={@google_calendar_url}
          target="_blank"
          rel="noopener"
          class="inline-flex items-center gap-1.5 text-[11px] font-bold text-muted hover:text-ink"
        >
          <.icon name="tabler-calendar-plus" class="size-4" /> Agenda
        </a>
        <a
          :if={@google_calendar_url}
          href={"/r/" <> @slug <> "/calendar.ics"}
          download
          class="inline-flex items-center gap-1.5 text-[11px] font-bold text-muted hover:text-ink"
        >
          <.icon name="tabler-download" class="size-4" /> .ics
        </a>
      </div>
    </section>
    """
  end

  defp render_markdown(text) when is_binary(text) do
    text
    # WhatsApp markup first, so what the organizer typed becomes markdown before
    # anything else looks at it. Then the quote neutralizer, which has to be the
    # last thing standing between user text and Earmark — swapping these two
    # would let a converted span reintroduce a quote after it was made safe.
    |> WhatsMarkup.to_markdown()
    |> neutralize_attribute_injection()
    |> Earmark.as_html(breaks: true, escape: true, compact_output: false)
    |> case do
      {:ok, html, _warnings} -> html
      {:error, html, _warnings} -> html
    end
  end

  # Earmark 1.4.x interpolates link/image URLs and titles into `href`/`src`/`title`
  # attributes without escaping double quotes, so `[x](http://a/?b=c" onerror="alert(1))`
  # closes the attribute and injects an event handler (EEF-CVE-2026-48591, no patched
  # release — the package is retired). `escape: true` does not cover this: it escapes
  # markup in text, not quotes inside generated attributes.
  #
  # Writes here are anonymous, so this is reachable by any visitor. Replacing the quote
  # with its HTML entity before parsing means whatever reaches an attribute can no longer
  # terminate it, while the character still renders as a quote in body text. Markdown
  # itself goes away in the structured-fields migration, which removes this path entirely.
  defp neutralize_attribute_injection(text), do: String.replace(text, "\"", "&quot;")
end
