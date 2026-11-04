defmodule RolezinhoWeb.EventLive do
  @moduledoc """
  Public event page. Renders the header/footer markdown and the two lists,
  and exposes actions for both anonymous visitors and the admin.
  """
  use RolezinhoWeb, :live_view

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.Cash
  alias Rolezinho.Event.FormField
  alias Rolezinho.Event.Meta
  alias Rolezinho.Event.Policy
  alias Rolezinho.Event.WhatsMarkup
  alias Rolezinho.Events
  alias Rolezinho.Group
  alias Rolezinho.Groups
  alias Rolezinho.Pix
  alias RolezinhoWeb.Components.UI.BottomSheet
  alias RolezinhoWeb.Plugs.Participant

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    # Look up with `:any` visibility so we can also serve archived
    # (`:done`) events to their owner — the anonymous-public gate is a
    # second, in-mount check. Without this, an organizer couldn't
    # reach the event page of their own archived rolê, which broke
    # the clone ("Repetir esse rolê") entry point that only renders
    # on `:done`.
    with %Event{} = event <- Events.find(slug, visibility: :any),
         true <- visible_to_caller?(event, socket),
         :ok <- gated_by_group(event, socket) do
      if connected?(socket), do: Events.subscribe(slug)

      {:ok,
       socket
       |> assign(:show_password_in_share?, false)
       |> assign_event(event)
       |> assign(:new_main_name, "")
       |> assign(:new_wait_name, "")
       |> assign(:editing_main, nil)
       |> assign(:editing_wait, nil)
       |> assign(:expanded_rows, MapSet.new())
       |> assign(:confirming_removal, nil)}
    else
      # Password-protected group we haven't unlocked yet: send the
      # visitor to the group page (SECURITY.md §3) so they enter the
      # bundle through its single door.
      {:redirect, group_slug} ->
        {:ok,
         socket
         |> put_flash(
           :info,
           "Esse rolê faz parte de um grupo protegido. Digite a senha do grupo pra ver."
         )
         |> push_navigate(to: ~p"/g/#{group_slug}")}

      # Same "not found" for nil (slug doesn't resolve) AND for a real
      # event the caller cannot see — no reason to reveal that a slug
      # they can't reach exists at all.
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Rolezinho não encontrado.")
         |> push_navigate(to: ~p"/")}
    end
  end

  # Whether the caller may open this event's page at all. Public
  # statuses are open to anyone; anything else (`:done`, plus any
  # future non-public status) requires admin OR the event's own
  # organizer, so an owner keeps a way back to their own arquivo.
  # The password gate applies inside the page — not here.
  defp visible_to_caller?(%Event{} = event, socket) do
    cond do
      event.status in Event.public_statuses() -> true
      socket.assigns[:current_admin?] == true -> true
      Policy.can_edit?(event, mount_policy_opts(socket, event)) -> true
      true -> false
    end
  end

  # Same shape `assign_identity/3` builds later; extracted so
  # `visible_to_caller?/2` can ask the same question in mount before
  # the socket has been enriched. Named `mount_policy_opts/2` to keep
  # it separate from the `policy_opts/1` used post-mount (which reads
  # the already-assigned socket.assigns.event / .organizer? / .participant_id).
  defp mount_policy_opts(socket, %Event{} = event) do
    [
      admin?: socket.assigns[:current_admin?] == true,
      organizer?:
        Participant.organizer?(
          %{"organizer_tokens" => socket.assigns[:organizer_tokens] || %{}},
          event
        ),
      participant_id: Map.get(socket.assigns[:participants] || %{}, event.slug),
      current_user_id: socket.assigns[:current_user_id]
    ]
  end

  # Only redirect when the group is password-protected *and* the visitor is not
  # yet unlocked (and not admin). A group with no password sets no gate on its
  # events — they keep their own individual password behaviour, if any.
  defp gated_by_group(%Event{group_id: nil}, _socket), do: :ok

  defp gated_by_group(%Event{group_id: gid}, socket) do
    with %Group{} = group <- Groups.get(gid),
         true <- Group.password_protected?(group),
         false <- socket.assigns.current_admin?,
         false <- MapSet.member?(socket.assigns.unlocked_groups, group.slug) do
      {:redirect, group.slug}
    else
      _ -> :ok
    end
  end

  # Group unlock cascades to the events inside: if the caller entered the
  # group's password, they get to see the events even if the events themselves
  # have their own password set. This is the "inherited auth" the product spec
  # calls for.
  defp compute_unlocked?(%Event{} = event, socket) do
    cond do
      socket.assigns.current_admin? -> true
      group_password_bypass?(event, socket) -> true
      group_password_gates?(event) -> false
      not Event.password_protected?(event) -> true
      MapSet.member?(socket.assigns.unlocked_events, event.slug) -> true
      true -> false
    end
  end

  defp group_password_bypass?(%Event{group_id: nil}, _socket), do: false

  defp group_password_bypass?(%Event{group_id: gid}, socket) do
    with %Group{} = group <- Groups.get(gid),
         true <- Group.password_protected?(group) do
      MapSet.member?(socket.assigns.unlocked_groups, group.slug)
    else
      _ -> false
    end
  end

  defp group_password_gates?(%Event{group_id: nil}), do: false

  defp group_password_gates?(%Event{group_id: gid}) do
    case Groups.get(gid) do
      %Group{} = group -> Group.password_protected?(group)
      _ -> false
    end
  end

  defp assign_event(socket, %Event{} = event) do
    url = url_for(event)
    {meta, stripped_header} = Meta.extract(event.header)

    # `unlocked?` is what tells the template whether to show the location,
    # names, description, calendar buttons, join form and so on. Mirroring the
    # controllers: an unlocked group bypasses everything; a locked group gates
    # everything; only after that does the event's own password come in.
    #
    # Note: `mount/3` already sends the visitor to the group's unlock panel
    # when the group gate is closed and the caller isn't admin. This branch is
    # what makes the LiveView do the right thing anyway if that ever changes.
    unlocked? = compute_unlocked?(event, socket)

    # When the visitor hasn't unlocked, hide everything that could reveal
    # sensitive info: the location line, the free-form description block, the
    # PIX QR (which sits inside the description), and the calendar buttons.
    # The Quando (date/time) block on the widget still renders when set — it's
    # a common "save the date" preview.
    display_meta = if unlocked?, do: meta, else: %{meta | local: nil}
    display_header = if unlocked?, do: stripped_header, else: ""

    google_calendar_url =
      if unlocked?, do: Meta.google_url(display_meta, event.title, url), else: nil

    # If the event belongs to a group, the back-crumb should point at that
    # group instead of the home page — that's where the event lives, and
    # it saves the visitor from clicking "back to Rolezinhos" only to have
    # to hunt the group down again. A stranger following the direct link
    # still gets a useful destination: the group page will either render
    # its contents (if public / unlocked) or its unlock panel (which is
    # the correct next step anyway).
    group_crumb = load_group_crumb(event)

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
    |> assign(:group_crumb, group_crumb)
    |> reset_share_toggle_if_disallowed()
    |> assign_shareable_text()
  end

  # Returns `{slug, name}` for the event's group, or `nil` when the event
  # isn't grouped. Kept minimal on purpose: the crumb only needs those two
  # fields and this runs on every assign_event rebuild.
  defp load_group_crumb(%Event{group_id: nil}), do: nil

  defp load_group_crumb(%Event{group_id: gid}) do
    case Groups.get(gid) do
      %Group{slug: slug, name: name} -> %{slug: slug, name: name}
      _ -> nil
    end
  end

  # Who this browser is *on this event*. The socket carries the session maps
  # (see RolezinhoWeb.Plugs.Participant), and both are scoped by slug so a claim
  # on one event never leaks into another.
  defp assign_identity(socket, %Event{} = event, unlocked?) do
    participant_id = Map.get(socket.assigns[:participants] || %{}, event.slug)

    # Two routes to `:organizer` on the socket: holding the event's
    # `organizer_token` in the session, or being signed in as the user who
    # created the event (ADR-0002). Either one earns the role for every
    # template branch that reads `@organizer?`.
    organizer? =
      Participant.organizer?(
        %{"organizer_tokens" => socket.assigns[:organizer_tokens] || %{}},
        event
      ) or created_by_current_user?(event, socket)

    user_id = socket.assigns[:current_user_id]

    socket
    |> assign(:participant_id, participant_id)
    |> assign(:organizer?, organizer?)
    |> assign(:mine_index, own_row_index(event, participant_id, user_id))
    |> assign_cash(event, organizer?)
    |> assign_join_availability(event, participant_id, organizer?, unlocked?)
  end

  defp created_by_current_user?(%Event{created_by_user_id: same}, %{
         assigns: %{current_user_id: same}
       })
       when is_integer(same),
       do: true

  defp created_by_current_user?(_event, _socket), do: false

  # Whether to offer the join action at all. Someone already on the list is not
  # offered it — the waiting list would take them a second time, and a list with
  # the same person twice is a list nobody trusts.
  defp assign_join_availability(socket, %Event{} = event, participant_id, organizer?, unlocked?) do
    user_id = socket.assigns[:current_user_id]

    opts = [
      admin?: socket.assigns.current_admin?,
      organizer?: organizer?,
      participant_id: participant_id,
      current_user_id: user_id
    ]

    can_join? =
      unlocked? and
        Policy.can_join?(event, opts) and
        is_nil(own_row_index(event, participant_id, user_id)) and
        is_nil(own_wait_index(event, participant_id, user_id)) and
        (not Event.main_full?(event) or event.wait_enabled)

    # RN-31: promoting is the organizer's call. The button used to render for
    # every visitor, which put a decision that reorders the list in the hands of
    # anyone who opened the page; `handle_event("promote", ...)` still asks the
    # policy, so this only stops offering what would be refused.
    socket
    |> assign(:can_promote?, Policy.can_promote?(event, opts))
    |> assign(:can_join?, can_join?)
    |> assign(:can_edit_event?, Policy.can_edit?(event, opts))
    |> assign(:confirmed_names, confirmed_names(event, unlocked?))
    |> assign(:party_room, party_room(event))
    |> assign(:extra_fields, extra_fields(event))
    # Autocomplete suggestions for the join form's name + guest fields.
    # `[]` for anonymous callers (no cross-event history to draw from),
    # otherwise the 25 most recent canonical names this user has typed.
    |> assign(:recent_names, Events.recent_names_for_user(user_id, 25))
    # Snapshot the policy inputs for the template. The pencil affordance on
    # each row asks `Policy.can_edit_row?/3` for the answer and needs the
    # same shape `handle_event/3` uses server-side, so keeping the two in
    # lockstep here (rather than rebuilding it in HEEx) rules out drift.
    |> assign(:policy_opts, opts)
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

  # "My" row on the wait list, matched by either identity (per-device token
  # or signed-in user). Returns a 1-based index or nil.
  defp own_wait_index(%Event{wait_list: list}, participant_id, user_id) do
    case Enum.find_index(list, &Attendee.owns?(&1, participant_id, user_id)) do
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
  # "My" row on the main list, matched by either identity. Same shape as
  # `own_wait_index/3`.
  defp own_row_index(%Event{main_list: list}, participant_id, user_id) do
    case Enum.find_index(list, &Attendee.owns?(&1, participant_id, user_id)) do
      nil -> nil
      index -> index + 1
    end
  end

  # Mirrors Event.Policy for the template. The handler asks the policy again on
  # every action: this only decides what to draw, and drawing nothing is not a
  # gate. `owns_row?` is per-row ownership (via participant token or user id) so
  # a party leader who joined with guests can act on every row they created —
  # not just the first one. `mine?` (from `mine_index`) still exists for the
  # highlight and the self-remove-confirm copy, but is not the gate.
  defp can_toggle?(_event, %Attendee{name: ""}, _owns_row?, _admin?, _organizer?), do: false
  defp can_toggle?(_event, _attendee, _owns_row?, true, _organizer?), do: true
  defp can_toggle?(_event, _attendee, _owns_row?, _admin?, true), do: true
  defp can_toggle?(_event, _attendee, owns_row?, _admin?, _organizer?), do: owns_row?

  defp can_remove?(%Attendee{name: ""}, _owns_row?, _admin?, _organizer?), do: false
  defp can_remove?(_attendee, _owns_row?, true, _organizer?), do: true
  defp can_remove?(_attendee, _owns_row?, _admin?, true), do: true
  defp can_remove?(_attendee, owns_row?, _admin?, _organizer?), do: owns_row?

  # Per-row ownership check for the template. Delegates to the same
  # `Attendee.owns?/3` the server-side policy uses so the drawn affordance
  # and the authorization gate never disagree.
  defp row_owned_by?(%Attendee{} = attendee, policy_opts) do
    Attendee.owns?(
      attendee,
      Keyword.get(policy_opts, :participant_id),
      Keyword.get(policy_opts, :current_user_id)
    )
  end

  # RN-22: removal always confirms, naming who is being removed so a mistap in a
  # dense list is caught before it happens.
  defp remove_confirm(true, _name), do: "Sair da lista?"
  defp remove_confirm(false, name), do: "Remover #{name} da lista?"

  defp debt_summary(%{missing_cents: missing} = cash) do
    "Falta#{if missing_plural?(cash), do: "m"} #{Cash.format_amount(missing)}" <>
      debtors_part(cash) <> empty_seats_part(cash) <> "."
  end

  defp missing_plural?(%{debtors: debtors, empty_seats: seats}), do: length(debtors) + seats > 1

  defp debtors_part(%{debtors: []}), do: ""
  defp debtors_part(%{debtors: [_one]}), do: " · 1 pessoa não pagou o Pix"
  defp debtors_part(%{debtors: debtors}), do: " · #{length(debtors)} pessoas não pagaram o Pix"

  defp empty_seats_part(%{empty_seats: 0}), do: ""

  defp empty_seats_part(%{empty_seats: seats, empty_seats_cents: cents}),
    do:
      " · #{seats} #{if seats == 1, do: "vaga vazia", else: "vagas vazias"} (#{Cash.format_amount(cents)})"

  # How many of the people on the list have declared payment. Returns nil when
  # there is nothing to count — an empty list, or a free event where the check
  # would be reporting on money nobody owes.
  defp paid_summary(%Event{} = event) do
    case {Cash.per_person_cents(event), Cash.summary(event)} do
      {nil, _} -> nil
      {_, %{total_count: 0}} -> nil
      {_, %{paid_count: paid, total_count: paid}} -> "todos pagaram"
      {_, %{paid_count: paid, total_count: total}} -> "#{paid} de #{total} já pagaram"
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
  # Same rule as PaymentLive: prefer the explicit type when set. Legacy
  # events (nil type) still work via `Pix.classify/1`.
  defp pix_for(%Event{pix_key: key, pix_key_type: type} = event)
       when is_binary(key) and key != "" and is_atom(type) and not is_nil(type) do
    case Pix.canonicalize(key, type) do
      {:ok, canonical} ->
        # `display_as/2` respects the explicit type; `display/1` would
        # guess and mislabel a bare 11-digit phone as a CPF.
        %{key: canonical, raw: key, display: Pix.display_as(key, type) || key}

      :error ->
        Pix.detect(event.header)
    end
  end

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
  # Passed through so the pencil affordance can ask `Policy.can_edit_row?/3`
  # — which now covers row-owners too, not just admin (RN-24).
  attr :policy_opts, :list, required: true
  attr :extra_fields, :list, default: []

  defp event_participant_row(assigns) do
    assigns =
      assigns
      |> assign(:mine?, assigns.mine_index == assigns.index)
      |> assign(:owns_row?, row_owned_by?(assigns.attendee, assigns.policy_opts))
      |> assign(
        :can_edit?,
        assigns.unlocked? and
          String.trim(assigns.attendee.name) != "" and
          Policy.can_edit_row?(assigns.event, assigns.attendee, assigns.policy_opts)
      )
      |> assign(
        :inline_hint,
        assigns.unlocked? && inline_value_hint(assigns.attendee, assigns.extra_fields)
      )

    ~H"""
    <.participant_row
      number={@index}
      name={display_name(@attendee.name, @unlocked?)}
      paid={@attendee.paid}
      highlighted={@mine?}
      divider={@index < length(@event.main_list)}
      paid_click={
        can_toggle?(@event, @attendee, @owns_row?, @current_admin?, @organizer?) &&
          "toggle_paid_main"
      }
      join_click={@can_join? and BottomSheet.show("join-sheet")}
      empty_label="Vaga livre"
      join_label="Entrar"
      phx-value-index={@index}
    >
      <:name_suffix :if={@inline_hint}>· {@inline_hint}</:name_suffix>
      <:actions>
        <button
          :if={@can_edit?}
          type="button"
          phx-click="start_edit_main"
          phx-value-index={@index}
          class="-mx-1.5 grid size-11 shrink-0 place-items-center text-ink/35"
          aria-label={"Editar #{@attendee.name}"}
        >
          <.icon name="tabler-pencil" class="size-4" />
        </button>
        <button
          :if={can_remove?(@attendee, @owns_row?, @current_admin?, @organizer?)}
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

  # Compact single-value hint rendered right after the name for the 1-field
  # case (RN-63 spec addendum): only when the event has exactly one non-locked
  # form field and the attendee has a value for it. Multi-field rows use the
  # disclosure panel below the row instead.
  defp inline_value_hint(%Attendee{values: values}, [%FormField{} = field]) do
    case Map.get(values || %{}, field.id) do
      value when is_binary(value) and value != "" -> "#{field.label}: #{value}"
      _ -> nil
    end
  end

  defp inline_value_hint(_attendee, _fields), do: nil

  # Whether the multi-field disclosure panel has any reason to render. For a
  # 1-field event the inline hint already covers it. For 0-field events (or
  # rows whose owner joined before the field was added and never filled it)
  # there is nothing to disclose, so no toggle appears either.
  defp show_extras_panel?(%Attendee{} = attendee, fields) do
    length(fields) >= 2 and any_value?(attendee, fields)
  end

  defp any_value?(%Attendee{values: values}, fields) do
    values = values || %{}

    Enum.any?(fields, fn field ->
      value = Map.get(values, field.id)
      is_binary(value) and value != ""
    end)
  end

  # The disclosure panel that appears below a multi-field row. Renders the
  # toggle button always (when the row has any values); when open, unfolds
  # a compact key/value list of every field the attendee filled.
  attr :list, :string, required: true, values: ~w(main wait)
  attr :index, :integer, required: true
  attr :attendee, Attendee, required: true
  attr :extra_fields, :list, required: true
  attr :expanded?, :boolean, required: true

  defp attendee_extras(assigns) do
    ~H"""
    <div class="px-3.5 pb-3 pt-0">
      <button
        type="button"
        phx-click="toggle_row_extras"
        phx-value-list={@list}
        phx-value-index={@index}
        aria-expanded={to_string(@expanded?)}
        class="ml-6 inline-flex items-center gap-1 text-[11px] font-semibold text-muted hover:text-ink"
      >
        <.icon
          name={if @expanded?, do: "tabler-minus", else: "tabler-plus"}
          class="size-3.5"
        />
        {if @expanded?, do: "Menos", else: "Ver detalhes"}
      </button>

      <dl :if={@expanded?} class="ml-6 mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
        <%= for field <- @extra_fields, value = Map.get(@attendee.values || %{}, field.id), is_binary(value) and value != "" do %>
          <dt class="text-[11px] font-semibold uppercase tracking-wide text-muted">
            {field.label}
          </dt>
          <dd class="text-[12px] text-base-content">{value}</dd>
        <% end %>
      </dl>
    </div>
    """
  end

  # The inline edit form that replaces the row while `editing_{list} == i`.
  # A single stacked form for name + every non-locked field, submits
  # `update_{list}` and gets authorized server-side against `can_edit_row?/3`.
  attr :list, :string, required: true, values: ~w(main wait)
  attr :index, :integer, required: true
  attr :attendee, Attendee, required: true
  attr :extra_fields, :list, required: true

  defp attendee_edit_form(assigns) do
    ~H"""
    <form
      phx-submit={"update_#{@list}"}
      phx-value-index={@index}
      class="space-y-2 border-b border-ink/6 px-3.5 py-3"
      autocomplete="off"
    >
      <label class="block">
        <span class="mb-1 block text-[11px] font-bold text-muted">Nome</span>
        <input
          type="text"
          name="name"
          value={@attendee.name}
          class={[field_class(), "w-full"]}
          maxlength="60"
          data-1p-ignore="true"
          data-lpignore="true"
          data-bwignore="true"
          data-form-type="other"
          autofocus
        />
      </label>

      <label :for={field <- @extra_fields} class="block">
        <span class="mb-1 block text-[11px] font-bold text-muted">
          {field.label}{if field.required, do: " *"}
        </span>
        <input
          type={field.type}
          name={"values[#{field.id}]"}
          value={Map.get(@attendee.values || %{}, field.id, "")}
          class={[field_class(), "w-full"]}
          maxlength="200"
          placeholder={field.placeholder}
          data-1p-ignore="true"
          data-lpignore="true"
          data-bwignore="true"
          data-form-type="other"
        />
      </label>

      <div class="flex items-center justify-end gap-2 pt-1">
        <button
          type="button"
          phx-click="cancel_edit"
          class="px-2 py-1.5 text-[11px] font-bold text-muted"
        >
          Cancelar
        </button>
        <button
          type="submit"
          class="rounded-lg bg-ink px-2.5 py-1.5 text-[11px] font-bold text-ink-content"
        >
          Salvar
        </button>
      </div>
    </form>
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
  # ADR-0002: `current_user_id` is what lets a signed-in creator resolve to
  # `:organizer` without holding the token.
  defp policy_opts(socket) do
    [
      admin?: socket.assigns.current_admin?,
      organizer?: socket.assigns[:organizer?] || false,
      participant_id: socket.assigns[:participant_id],
      current_user_id: socket.assigns[:current_user_id]
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
    with {:ok, position} <- parse_position(index),
         %Attendee{} = attendee <- fetch_row(socket.assigns.event, :main, position),
         true <- Policy.can_edit_row?(socket.assigns.event, attendee, policy_opts(socket)) do
      {:noreply, assign(socket, :editing_main, position)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("start_edit_wait", %{"index" => index}, socket) do
    with {:ok, position} <- parse_position(index),
         %Attendee{} = attendee <- fetch_row(socket.assigns.event, :wait, position),
         true <- Policy.can_edit_row?(socket.assigns.event, attendee, policy_opts(socket)) do
      {:noreply, assign(socket, :editing_wait, position)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_main, nil) |> assign(:editing_wait, nil)}
  end

  # Server-side authorization mirrors the template gate: admin or
  # organizer only. A hostile client that pushes this event without the
  # right role is silently ignored, same shape as the row handlers below.
  def handle_event("toggle_hidden", _params, socket) do
    if Policy.can_edit?(socket.assigns.event, policy_opts(socket)) do
      {:ok, event} = Events.set_hidden(socket.assigns.event, not socket.assigns.event.hidden)

      message =
        if event.hidden, do: "Rolê agora está oculto.", else: "Rolê agora aparece na home."

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> assign_event(event)}
    else
      {:noreply, socket}
    end
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

  # Update path used by the row-owner flow: name + form-field answers in one
  # submit. The permission check runs on the resolved attendee: a stale index
  # or someone else's row silently fails, matching the row-action pattern in
  # `authorize_row/5`.
  def handle_event("update_main", %{"index" => index} = params, socket),
    do: do_update_row(socket, :main, index, params)

  def handle_event("update_wait", %{"index" => index} = params, socket),
    do: do_update_row(socket, :wait, index, params)

  # Disclosure toggle for the extras panel. Multiple rows can be open at
  # once (an organizer scanning a list wants to compare answers), so this
  # is a MapSet of `{list, index}` rather than a single value.
  def handle_event("toggle_row_extras", %{"list" => list, "index" => index}, socket) do
    with {:ok, position} <- parse_position(index),
         {:ok, list_atom} <- parse_list(list) do
      key = {list_atom, position}
      set = socket.assigns.expanded_rows

      new_set =
        if MapSet.member?(set, key),
          do: MapSet.delete(set, key),
          else: MapSet.put(set, key)

      {:noreply, assign(socket, :expanded_rows, new_set)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("grow_main", _params, socket) do
    require_can_edit!(socket)
    new_size = socket.assigns.event.main_capacity + 1
    {:ok, event} = Events.resize_main(socket.assigns.event, new_size)
    {:noreply, assign_event(socket, event)}
  end

  def handle_event("shrink_main", _params, socket) do
    require_can_edit!(socket)
    new_size = socket.assigns.event.main_capacity - 1
    {:ok, event} = Events.resize_main(socket.assigns.event, max(new_size, 1))
    {:noreply, assign_event(socket, event)}
  end

  def handle_event("clone", _params, socket) do
    # Cloning is a copy-then-navigate flow; the copy's ownership goes
    # to whoever performed the clone (see `Events.clone/2`), which is
    # what an editor of the source event should expect — their repeat,
    # under their name. No need to gate on admin any more.
    require_can_edit!(socket)

    # ADR-0002: the clone's `created_by_user_id` points at the caller (the
    # admin performing the repeat), so they can manage it from any device
    # they sign into. `nil` when the admin is on the password-bypass path
    # without a GitHub session — the event still gets created, just without
    # the durable-ownership pointer.
    created_by = socket.assigns[:current_user_id]

    case Events.clone(socket.assigns.event, created_by_user_id: created_by) do
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

  # Shared plumbing for the row-owner update flow. Kept next to
  # `authorize_row/5` because it's the same shape: parse position, resolve
  # row, ask policy, run operation — the only difference is that this one
  # takes a params map instead of a fixed op.
  defp do_update_row(socket, list, raw_index, params) do
    with {:ok, position} <- parse_position(raw_index),
         %Attendee{} = attendee <- fetch_row(socket.assigns.event, list, position),
         true <- Policy.can_edit_row?(socket.assigns.event, attendee, policy_opts(socket)),
         {:ok, event} <- persist_row_update(socket.assigns.event, list, position, params) do
      {:noreply,
       socket
       |> assign_event(event)
       |> clear_editing(list)}
    else
      _ -> {:noreply, socket}
    end
  end

  defp persist_row_update(event, :main, position, params),
    do: Events.update_main(event, position, params)

  defp persist_row_update(event, :wait, position, params),
    do: Events.update_wait(event, position, params)

  defp clear_editing(socket, :main), do: assign(socket, :editing_main, nil)
  defp clear_editing(socket, :wait), do: assign(socket, :editing_wait, nil)

  defp parse_list("main"), do: {:ok, :main}
  defp parse_list("wait"), do: {:ok, :wait}
  defp parse_list(_), do: :error

  defp require_admin!(socket) do
    unless socket.assigns.current_admin? do
      raise "unauthorized"
    end

    :ok
  end

  # Companion of `require_admin!/1`: asserts the caller passes
  # `Policy.can_edit?/2` on the current event. Same shape as the
  # `require_can_edit!/1` in `EventEditLive`, kept in sync so the two
  # surfaces agree on "who owns this event".
  defp require_can_edit!(socket) do
    unless Policy.can_edit?(socket.assigns.event, policy_opts(socket)) do
      raise "unauthorized: not an editor of this event"
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
    <Layouts.app
      flash={@flash}
      current_admin?={@current_admin?}
      current_user={@current_user}
      page_title={@page_title}
    >
      <:action :if={@can_join?}>
        <button
          type="button"
          phx-click={BottomSheet.show("join-sheet")}
          class="mx-auto block w-full max-w-[36rem] rounded-cta bg-ink px-4 py-4 text-[15px] font-bold text-ink-content shadow-cta transition-transform active:scale-[.97] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        >
          {join_label(@event)}
        </button>
      </:action>

      <article class="mx-auto max-w-[36rem] space-y-8">
        <header class="space-y-3">
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1.5 text-xs text-muted">
            <.link
              :if={@group_crumb}
              navigate={~p"/g/#{@group_crumb.slug}"}
              class="shrink-0 whitespace-nowrap hover:text-ink"
            >← {@group_crumb.name}</.link>
            <.link
              :if={is_nil(@group_crumb)}
              navigate={~p"/"}
              class="shrink-0 whitespace-nowrap hover:text-ink"
            >← Rolezinhos</.link>
            <span class="shrink-0">·</span>
            <span class="min-w-0 truncate">/r/{@event.slug}</span>
            <.crumb_badge :if={@event.hidden} tone="warning">Oculto</.crumb_badge>
            <.crumb_badge :if={@event.status == :done} tone="neutral">Concluído</.crumb_badge>
            <.crumb_badge
              :if={@event.status == :maybe}
              tone="info"
              title={Event.maybe_status_hint()}
            >
              Averiguando Resenha
            </.crumb_badge>
            <.crumb_badge :if={@signups_locked?} tone="info">Só pagamentos</.crumb_badge>
          </div>

          <!-- Screen actions belong beside the title. Loose between two cards
               they read as an orphan with no owner. -->
          <div class="flex items-start justify-between gap-3">
            <h1 class="min-w-0 flex-1 text-2xl font-extrabold tracking-tight">{@event.title}</h1>

            <div class="flex shrink-0 items-center gap-1.5">
              <button
                type="button"
                phx-click={BottomSheet.show("share-sheet")}
                class="grid size-11 place-items-center rounded-full bg-ink/[0.06] text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
                aria-label="Compartilhar a lista"
              >
                <.icon name="tabler-share" class="size-[18px]" />
              </button>
              <!-- Oculto toggle for admins + organizers. Puts the visibility
                   decision on the event page itself so a role owner does
                   not have to know that /admin/r/:slug/edit exists (it is
                   still admin-only). Server-side authorization runs on the
                   handler side too. -->
              <button
                :if={@can_edit_event?}
                type="button"
                phx-click="toggle_hidden"
                aria-pressed={to_string(@event.hidden)}
                aria-label={if @event.hidden, do: "Tornar público", else: "Tornar oculto"}
                class={[
                  "grid size-11 place-items-center rounded-full focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
                  if(@event.hidden,
                    do: "bg-warning/15 text-warning",
                    else: "bg-ink/[0.06] text-ink"
                  )
                ]}
              >
                <.icon
                  name={if @event.hidden, do: "tabler-eye-off", else: "tabler-eye"}
                  class="size-[18px]"
                />
              </button>
              <.link
                :if={@can_edit_event?}
                navigate={~p"/admin/r/#{@event.slug}/edit"}
                class="grid size-11 place-items-center rounded-full bg-ink/[0.06] text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
                aria-label="Editar o rolê"
              >
                <.icon name="tabler-pencil" class="size-[18px]" />
              </.link>
            </div>
          </div>

          <.maybe_notice :if={@event.status == :maybe} />

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
            amount={Cash.amount_line_text(@event)}
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
          :if={@can_edit_event? and @event.status == :done}
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
            <div :if={@can_edit_event?} class="inline-flex -space-x-px">
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
                <.attendee_edit_form
                  list="main"
                  index={i}
                  attendee={att}
                  extra_fields={@extra_fields}
                />
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
                    policy_opts={@policy_opts}
                    extra_fields={@extra_fields}
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
                  policy_opts={@policy_opts}
                  extra_fields={@extra_fields}
                />

                <.attendee_extras
                  :if={@unlocked? and show_extras_panel?(att, @extra_fields)}
                  list="main"
                  index={i}
                  attendee={att}
                  extra_fields={@extra_fields}
                  expanded?={MapSet.member?(@expanded_rows, {:main, i})}
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
              class="rounded-xl bg-base-200"
            >
              <%= if @editing_wait == i do %>
                <.attendee_edit_form
                  list="wait"
                  index={i}
                  attendee={att}
                  extra_fields={@extra_fields}
                />
              <% else %>
                <div class="flex items-center gap-3 px-3 py-2">
                  <span class="text-sm font-mono w-8 text-right text-base-content/50">{i}.</span>

                  <span class={[
                    "flex-1 min-w-0 truncate font-medium",
                    not @unlocked? && "tracking-widest text-base-content/60"
                  ]}>
                    <span class="align-middle">{display_name(att.name, @unlocked?)}</span>
                    <span
                      :if={@unlocked? and inline_value_hint(att, @extra_fields)}
                      class="ml-1.5 align-middle text-[11px] font-normal text-muted"
                    >· {inline_value_hint(att, @extra_fields)}</span>
                  </span>

                  <div class="flex items-center gap-1 shrink-0">
                    <!-- Same rationale as before: promotion stays visible while
                         the main list is full, only disabled, so the queue
                         never reads as a row that lost its only action. -->
                    <button
                      :if={@can_promote?}
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
                      :if={@unlocked? and Policy.can_edit_row?(@event, att, @policy_opts)}
                      type="button"
                      phx-click="start_edit_wait"
                      phx-value-index={i}
                      class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:pointer-events-none px-2 py-1 text-xs hover:bg-base-200"
                      title="Editar"
                    >
                      <.icon name="tabler-pencil" class="size-3.5" />
                    </button>
                    <button
                      :if={@current_admin?}
                      type="button"
                      phx-click="remove_wait"
                      phx-value-index={i}
                      data-confirm="Remover da reserva?"
                      class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:pointer-events-none px-2 py-1 text-xs hover:bg-base-200 text-error"
                      title="Remover"
                    >
                      <.icon name="tabler-x" class="size-3.5" />
                    </button>
                  </div>
                </div>

                <.attendee_extras
                  :if={@unlocked? and show_extras_panel?(att, @extra_fields)}
                  list="wait"
                  index={i}
                  attendee={att}
                  extra_fields={@extra_fields}
                  expanded?={MapSet.member?(@expanded_rows, {:wait, i})}
                />
              <% end %>
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

        <!-- Autocomplete pool for the user's own name. Empty for anonymous
             callers — no cross-event history to pull from — so the browser
             just doesn't offer suggestions, which is the right no-op. -->
        <datalist id="join-name-suggestions">
          <option :for={name <- @recent_names} value={name} />
        </datalist>

        <!--
          Same pool, but for the guest fields, and filtered live by the
          `.PartyGuests` hook to exclude the name the user just typed as
          their own — no reason to suggest yourself as your own guest.
          Renders as a copy of the name pool on the server; the hook
          prunes it as the name field changes. Two datalists rather than
          one so the user's own field keeps ALL its suggestions (they
          are typing prefix-first; the browser already stops offering
          the option once it fully matches, so no dedup needed there).
        -->
        <datalist id="join-guest-suggestions">
          <option :for={name <- @recent_names} value={name} />
        </datalist>

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
            `autocomplete="off"` + the four vendor-specific ignore attrs
            (1Password / LastPass / Bitwarden / 1Password form-type) opt out
            of every mainstream identity autofill. This sheet is small and
            popover-y — a password manager suggestion floating over it is
            more disruptive than helpful — and we already prefill the name
            from the /me profile via the `.JoinDefaults` hook + localStorage,
            which is a strictly better UX than the browser's own guess.

            `list=` is orthogonal to `autocomplete` — the datalist above
            drives our own "names you've typed before" suggestions without
            competing with the password-manager suppressions.
          -->
          <label class="block">
            <span class="mb-1 block text-[11px] font-bold text-muted">Seu nome *</span>
            <input
              type="text"
              name="name"
              data-profile="name"
              data-name-field
              required
              maxlength="60"
              list="join-name-suggestions"
              autocomplete="off"
              data-1p-ignore="true"
              data-lpignore="true"
              data-bwignore="true"
              data-form-type="other"
              placeholder="Como te chamam no grupo"
              class="w-full rounded-row border border-ink/12 bg-base-100 px-3.5 py-3 text-[13px] font-semibold text-ink outline-none placeholder:font-normal placeholder:text-ink/35 focus:border-accent focus:ring-2 focus:ring-accent/20"
            />
          </label>

          <!-- RN-04: each companion becomes a row of their own, so the count
               here decides how many rows are created, not a "+2" suffix on one
               of them. -->
          <!-- RN-60/61/62: the questions this organizer chose to ask. Answers
               are scoped to this event and never rendered in the public list.
               Same ignore attrs as the name field: the popover context makes
               autofill more annoying than useful, and organizers pick these
               labels freely so browsers cannot know what they mean anyway. -->
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

          <!--
            One text field per guest slot the event can still hold. All are
            rendered up-front and toggled by the `.PartyGuests` hook based
            on the stepper's qty; that keeps party-size changes purely
            client-side (no round trip) and cheap (max 8 pre-rendered
            inputs is nothing compared to the shared datalist).

            Placeholder is "Convidado de <nome>" and updates live as the
            person types their own name above — the hook watches
            `[data-name-field]`.

            Same autocomplete guards as the main name field. `list=`
            hangs them off the shared datalist so the same recent-names
            suggestions appear on each guest slot.
          -->
          <div
            :if={@party_room > 1}
            id="party-guests"
            phx-hook=".PartyGuests"
            data-current-name=""
            class="mt-3 space-y-2"
          >
            <label
              :for={index <- 1..(@party_room - 1)}
              hidden
              data-guest-slot
              data-guest-index={index}
              class="block"
            >
              <span class="mb-1 block text-[11px] font-bold text-muted">
                Acompanhante {index}
              </span>
              <input
                type="text"
                name="guest_names[]"
                data-guest-input
                disabled
                maxlength="60"
                list="join-guest-suggestions"
                autocomplete="off"
                data-1p-ignore="true"
                data-lpignore="true"
                data-bwignore="true"
                data-form-type="other"
                placeholder="Convidado de você"
                class="w-full rounded-row border border-ink/12 bg-base-100 px-3.5 py-3 text-[13px] font-semibold text-ink outline-none placeholder:font-normal placeholder:text-ink/35 focus:border-accent focus:ring-2 focus:ring-accent/20"
              />
            </label>
          </div>

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
              // Someone who has filled in their name once should not type it
              // again in every list they join.
              let profile = {}
              try { profile = JSON.parse(localStorage.getItem(KEY) || "{}") } catch (_) {}

              // ADR-0002: for a signed-in user, seed the name from their
              // identity so the next join and the /me screen see it too.
              // We track which user id seeded the cached name so that
              // switching accounts on the same browser (e.g. signing out
              // of GitHub "lubien" and creating a fresh local account)
              // re-seeds instead of showing the previous identity's name.
              // If the user edited the name in /me under the current
              // account, `seededFromUserId` already matches and we leave
              // their choice alone.
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

        <script :type={Phoenix.LiveView.ColocatedHook} name=".PartyGuests">
          // The party controls: show N-1 guest inputs (where N is the qty
          // stepper), and keep every guest input's placeholder in sync
          // with the user's name so it always reads "Convidado de <name>".
          // Disabled + hidden inputs stay out of the POST body, which is
          // how we make sure only the active guest slots submit.
          export default {
            mounted() {
              const form = this.el.closest("form")
              if (!form) return

              const nameField = form.querySelector("[data-name-field]")
              const qtyField = form.querySelector("[data-field][name='qty']")
              const slots = Array.from(this.el.querySelectorAll("[data-guest-slot]"))

              const currentName = () => (nameField && nameField.value.trim()) || "você"

              const applyPlaceholders = () => {
                const label = `Convidado de ${currentName()}`
                slots.forEach((slot) => {
                  const input = slot.querySelector("[data-guest-input]")
                  if (input) input.placeholder = label
                })
              }

              const applyVisibility = () => {
                const qty = Number(qtyField ? qtyField.value : 1) || 1
                const active = Math.max(0, qty - 1)
                slots.forEach((slot, index) => {
                  const isActive = index < active
                  slot.hidden = !isActive
                  const input = slot.querySelector("[data-guest-input]")
                  if (input) input.disabled = !isActive
                })
              }

              // The name-shaped suggestion pool the guests use. We keep
              // an in-memory copy of every option the server rendered,
              // then re-materialize the datalist on every name change,
              // dropping any option whose canonical form matches what
              // the user just typed as their own. Same normalization
              // rule as `Rolezinho.Event.Attendee.canonical_name/1`:
              // trim, collapse whitespace, capitalize each word.
              const guestList = document.getElementById("join-guest-suggestions")
              const allSuggestions = guestList
                ? Array.from(guestList.querySelectorAll("option")).map((o) => o.value)
                : []

              const canonical = (s) =>
                (s || "")
                  .trim()
                  .split(/\s+/)
                  .filter(Boolean)
                  .map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
                  .join(" ")

              const applyGuestSuggestions = () => {
                if (!guestList) return
                const mine = canonical(nameField ? nameField.value : "")
                const kept = mine === ""
                  ? allSuggestions
                  : allSuggestions.filter((v) => canonical(v) !== mine)

                // Replace children in one pass; datalists are small
                // (≤25 options) so this is cheap and avoids per-option
                // toggling that some browsers ignore for `<option>`.
                guestList.replaceChildren(
                  ...kept.map((v) => {
                    const el = document.createElement("option")
                    el.value = v
                    return el
                  })
                )
              }

              // Watch the name field for placeholder + suggestion updates.
              if (nameField) {
                nameField.addEventListener("input", () => {
                  applyPlaceholders()
                  applyGuestSuggestions()
                })
              }

              // The stepper doesn't fire a change event on its hidden
              // input (it mutates `.value` directly), so we observe the
              // attribute + polling as a belt-and-suspenders. `input`
              // fires when the user types a number in dev tools; the
              // MutationObserver catches the stepper's programmatic
              // updates.
              if (qtyField) {
                qtyField.addEventListener("input", applyVisibility)
                const observer = new MutationObserver(applyVisibility)
                observer.observe(qtyField, { attributes: true, attributeFilter: ["value"] })
                // Also intercept clicks on the stepper buttons — they
                // set .value imperatively, which MutationObserver on the
                // `value` *attribute* may miss (properties vs attrs).
                const stepper = qtyField.closest("[data-min]")
                if (stepper) {
                  stepper.querySelectorAll("[data-step]").forEach((btn) => {
                    btn.addEventListener("click", () => setTimeout(applyVisibility, 0))
                  })
                }
              }

              applyPlaceholders()
              applyGuestSuggestions()
              applyVisibility()
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
              // The text already opens with the event URL; passing `url` too
              // makes share targets (WhatsApp, etc.) append it a second time.
              const text = this.el.dataset.text || location.href
              if (navigator.share) {
                try {
                  await navigator.share({ title, text })
                } catch (_) {}
              } else {
                try {
                  await navigator.clipboard.writeText(text)
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

  # ---------- Breadcrumb status badges ----------

  attr :tone, :string, required: true, values: ~w(warning info neutral)
  attr :rest, :global

  slot :inner_block, required: true

  defp crumb_badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex shrink-0 items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium",
        crumb_badge_tone(@tone)
      ]}
      {@rest}
    >{render_slot(@inner_block)}</span>
    """
  end

  defp crumb_badge_tone("warning"), do: "bg-warning/15 text-warning"
  defp crumb_badge_tone("info"), do: "bg-info/15 text-info"
  defp crumb_badge_tone("neutral"), do: "bg-ink/[0.08] text-muted"

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

  # Companion of the `:maybe` status pill: on the event page itself we
  # spell it out fully rather than lean on the tooltip — someone lands
  # here to decide whether to go, and the tentative nature is precisely
  # what shapes that decision. Same visual language as the payments-only
  # notice: info-toned rounded panel with an icon and one short paragraph.
  defp maybe_notice(assigns) do
    ~H"""
    <section class="rounded-2xl border border-info/40 bg-info/10 p-4 sm:p-5">
      <div class="flex items-start gap-3">
        <.icon name="tabler-help-circle" class="size-5 text-info shrink-0 mt-0.5" />
        <div class="space-y-1">
          <p class="font-semibold">Averiguando Resenha</p>
          <p class="text-sm text-base-content/80">
            {Event.maybe_status_hint()}
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
