defmodule RolezinhoWeb.EventEditLive do
  @moduledoc """
  Editor for an event. Reachable by admin OR by the event's own
  organizer (`Event.Policy.can_edit?/2`) — the URL still lives under
  `/admin/r/:slug/edit` for bookmark backward-compat, but the pipeline
  gate is off and each handler double-checks permission on the socket.

  A subset of controls (owner reassignment, group move, delete) stays
  admin-only regardless. Those handlers call `require_admin!/1`; the
  template hides them for non-admin editors.
  """
  use RolezinhoWeb, :live_view

  alias Rolezinho.Accounts
  alias Rolezinho.Event
  alias Rolezinho.Event.Meta
  alias Rolezinho.Event.Policy
  alias Rolezinho.Events
  alias Rolezinho.Group
  alias Rolezinho.Groups
  alias Rolezinho.Repo
  alias RolezinhoWeb.Plugs.Participant

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Events.find(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Rolezinho não encontrado.")
         |> push_navigate(to: ~p"/")}

      event ->
        if Policy.can_edit?(event, policy_opts(socket, event)) do
          {:ok,
           socket
           |> assign(:page_title, "Editar #{event.title}")
           # `slug_touched?` gates the live retag: once the user has typed into
           # the slug field themselves, we stop rewriting it from date edits.
           # `slug_reference_date` is the date the current slug's `-DD-MM` tail
           # matches — seeded from the event, updated after every successful
           # retag so a second date change also retags cleanly.
           |> assign(:slug_touched?, false)
           |> assign(:slug_reference_date, extract_current_date(event))
           |> assign_event(event)}
        else
          {:ok,
           socket
           |> put_flash(:error, "Você não pode editar esse rolê.")
           |> push_navigate(to: ~p"/r/#{event.slug}")}
        end
    end
  end

  # Snapshot of the caller's identity for `Policy.can_edit?/2` and every
  # in-handler `require_can_edit!/1` check. Mirrors `EventLive.policy_opts/1`
  # so the two surfaces agree on who counts as an organizer.
  defp policy_opts(socket, %Event{} = event) do
    [
      admin?: socket.assigns[:current_admin?] == true,
      organizer?:
        Participant.organizer?(
          %{"organizer_tokens" => socket.assigns[:organizer_tokens] || %{}},
          event
        ),
      participant_id: socket.assigns[:participant_id],
      current_user_id: socket.assigns[:current_user_id]
    ]
  end

  defp assign_event(socket, %Event{} = event) do
    {meta, description} = Meta.extract(event.header)

    socket
    |> assign(:event, event)
    |> assign(:main_size_input, to_string(event.main_capacity))
    # Mirror the create form's convention: 0 = wait list off, anything > 0
    # means it is on. The number itself is a hint (there is no runtime
    # capacity), so on the edit form we show a nominal 3 when the wait list
    # is on and 0 when it is off.
    |> assign(:wait_size_input, if(event.wait_enabled, do: "3", else: "0"))
    # One form to save every free-text/date field: title, description, meta
    # (local/date/time), payment (price/pix_key), password, and slug. Its
    # `phx-submit` (`save_details`) does slug rename first when the slug
    # changed and then a single atomic changeset via
    # `Events.update_full_details/2`. The number-only, select, radio and
    # button controls (capacity, status, group, owner, delete) each keep
    # their own dedicated section below.
    |> assign(:details_form, to_form(details_form_params(event, meta, description), as: :details))
    # Owner + group lists are only used by the admin-only sections at
    # the bottom of the template; a non-admin editor never reads them,
    # so skip the queries when the caller isn't admin. `@creator` is
    # still read by the admin-only "Dono" panel; scoped the same way.
    |> maybe_assign_admin_extras(event)
  end

  defp maybe_assign_admin_extras(socket, %Event{} = event) do
    # `:groups` is the option pool for the Grupo select. Admins see every
    # group; organizers see only the groups they can move the event into
    # (`Group.editable_by?/4` — admin or creator or session-unlocked),
    # PLUS the event's current group (so the current state is visible
    # even when they can't otherwise touch that group). Un-grouping is
    # always allowed for an editor — that's their own event.
    #
    # `:users` and `:creator` back the admin-only "Dono" panel and stay
    # admin-scoped — no need to load a users table for a non-admin who
    # can't reassign ownership anyway.
    if socket.assigns[:current_admin?] == true do
      socket
      |> assign(:groups, Groups.list_all())
      |> assign(:users, list_users())
      |> assign(:creator, Accounts.get_user(event.created_by_user_id))
    else
      socket
      |> assign(:groups, editable_groups_for(socket, event))
      |> assign(:users, [])
      |> assign(:creator, nil)
    end
  end

  defp editable_groups_for(socket, %Event{} = event) do
    unlocked = socket.assigns[:unlocked_groups] || MapSet.new()
    user_id = socket.assigns[:current_user_id]
    all = Groups.list_all()

    editable = Enum.filter(all, &Group.editable_by?(&1, false, unlocked, user_id))

    # Preserve the current group in the list even if the caller can't
    # otherwise reach it — without this, the select would show
    # "Nenhum" selected while the event still belongs to that group,
    # which is a lie.
    current = event.group_id && Enum.find(all, &(&1.id == event.group_id))

    if current && not Enum.any?(editable, &(&1.id == current.id)) do
      [current | editable]
    else
      editable
    end
  end

  defp details_form_params(%Event{} = event, %Meta{} = meta, description) do
    %{
      "slug" => event.slug,
      "title" => event.title,
      "description" => description,
      "category" => event.category || "",
      "local" => meta.local || "",
      "date" => (meta.date && Date.to_iso8601(meta.date)) || "",
      "time" => (meta.time && Calendar.strftime(meta.time, "%H:%M")) || "",
      "split_method" => Atom.to_string(event.split_method),
      "price" => price_input_value(event.price_cents),
      "total" => price_input_value(event.total_cents),
      "pix_key" => event.pix_key || "",
      "pix_key_type" => event.pix_key_type && Atom.to_string(event.pix_key_type),
      "password" => event.password || ""
    }
  end

  # Same suggestions the create form ships (see `EventNewLive.@category_suggestions`).
  # Kept in sync by hand — changing one without the other is the risk here; a
  # shared constant would be worth it once a third caller appears.
  defp category_suggestions, do: ~w(Trabalho Networking Esportes Social)

  # Small ordered list of every user, for the "Dono" select. Bounded by the
  # size of the accounts table — GitHub-authed users only, no big listing
  # planned. If this grows past comfort someday it becomes a search input.
  defp list_users do
    import Ecto.Query, only: [from: 2]
    Repo.all(from u in Accounts.User, order_by: [asc: u.github_login])
  end

  # Round-trips price_cents into the human-friendly string the create form and
  # this edit form both use. 1500 -> "15", 1550 -> "15,50", nil/0 -> "".
  defp price_input_value(nil), do: ""
  defp price_input_value(0), do: ""

  defp price_input_value(cents) when is_integer(cents) do
    reais = div(cents, 100)
    centavos = rem(cents, 100)

    if centavos == 0 do
      Integer.to_string(reais)
    else
      Integer.to_string(reais) <> "," <> String.pad_leading(Integer.to_string(centavos), 2, "0")
    end
  end

  @impl true
  def handle_event("validate_details", %{"details" => params} = payload, socket) do
    target = Map.get(payload, "_target", [])

    # Two steps, in this order:
    #   1. Always seed the form from the incoming params so the user's typing
    #      shows up. Any auto-retag will overwrite `slug` afterwards when it
    #      needs to; leaving the seed here means an untargeted change is a
    #      clean passthrough.
    #   2. Apply the target-specific behaviour — mark the slug as touched, or
    #      run the date-driven retag — which mutates the socket state (and,
    #      for retag, the form's `slug` value) further.
    socket = assign(socket, :details_form, to_form(params, as: :details))

    socket =
      case target do
        ["details", "slug"] ->
          assign(socket, :slug_touched?, true)

        ["details", "date"] ->
          retag_on_date_change(socket, params)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("save_details", %{"details" => params}, socket) do
    require_can_edit!(socket)
    original_event = socket.assigns.event
    submitted_slug = params |> Map.get("slug", "") |> to_string() |> String.trim()

    # Safety net for a submit that arrived without a preceding `phx-change`
    # (JS disabled, or a form recovery after a reconnect). The live handler
    # already updates the slug tag as the user edits the date; this preserves
    # the same behaviour when that live path did not run.
    effective_slug = maybe_retag_slug_with_date(original_event, submitted_slug, params)

    # Slug rename is a separate operation on purpose — it moves the URL and
    # broadcasts a `:moved` message on the old slug topic — so we do it first,
    # and only proceed to the bulk update if it succeeded. When the slug did
    # not change, `rename_slug/2` is a no-op that returns the same event.
    with {:ok, event} <- rename_if_changed(original_event, effective_slug),
         {:ok, event} <- Events.update_full_details(event, params) do
      socket =
        socket
        |> put_flash(:info, "Rolê atualizado.")
        |> assign_event(event)

      if event.slug != original_event.slug do
        # The URL just changed under us; the current /admin/r/<old>/edit is now
        # a 404. Push the browser to the new one.
        {:noreply, push_navigate(socket, to: ~p"/admin/r/#{event.slug}/edit")}
      else
        {:noreply, socket}
      end
    else
      {:error, :invalid_slug} ->
        {:noreply,
         put_flash(socket, :error, "Slug inválido. Use letras minúsculas, números e traços.")}

      {:error, :slug_taken} ->
        {:noreply, put_flash(socket, :error, "Esse slug já está em uso.")}

      {:error, errors} when is_map(errors) ->
        # Field-level validation failure (a `%{field => [msg | _]}` map from
        # the context). Re-render the form with the errors attached so the
        # bad field is highlighted inline — much friendlier than an opaque
        # "Não deu pra salvar" flash pointing at nowhere. Legacy events with
        # a pix_key but no pix_key_type land here on first save; the select
        # gets highlighted with "escolha o tipo da chave".
        {:noreply,
         socket
         |> put_flash(:error, flash_for_field_errors(errors))
         |> assign(
           :details_form,
           to_form(params, as: :details, errors: to_form_errors(errors))
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Não deu pra salvar: #{inspect(reason)}")}
    end
  end

  def handle_event("resize_lists", %{"main_size" => main_raw} = params, socket) do
    require_can_edit!(socket)
    wait_raw = Map.get(params, "wait_size", "0")

    with {:ok, main_size} <- parse_int_in_range(main_raw, 1, 500),
         {:ok, wait_size} <- parse_int_in_range(wait_raw, 0, 100),
         {:ok, event} <-
           Events.resize_lists(socket.assigns.event, main_size, wait_size > 0) do
      {:noreply,
       socket
       |> put_flash(:info, "Vagas atualizadas.")
       |> assign_event(event)}
    else
      {:error, :invalid_range} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Tamanhos inválidos. Na lista: 1–500. Na espera: 0–100."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Não deu pra atualizar: #{inspect(reason)}")}
    end
  end

  def handle_event("set_status", %{"status" => status}, socket) do
    require_can_edit!(socket)
    status_atom = String.to_existing_atom(status)
    {:ok, event} = Events.set_status(socket.assigns.event, status_atom)

    {:noreply,
     socket
     |> put_flash(:info, "Status atualizado.")
     |> assign_event(event)}
  end

  # Visibility toggle, orthogonal to status. Matches the inline
  # eye/eye-off toggle on `/r/:slug` — available to anyone with
  # `Policy.can_edit?/2`, not just admin.
  def handle_event("toggle_hidden", _params, socket) do
    require_can_edit!(socket)
    {:ok, event} = Events.set_hidden(socket.assigns.event, not socket.assigns.event.hidden)

    message = if event.hidden, do: "Rolê agora está oculto.", else: "Rolê agora aparece na home."

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> assign_event(event)}
  end

  # Move the event between groups (or out of any group).
  #
  #  * Un-grouping (`nil`) is always allowed for an editor — they own
  #    the event, they can pull it out of any bundle.
  #  * Moving INTO a group requires the caller to have edit access to
  #    that target group (`Group.editable_by?/4`: admin OR creator OR
  #    session-unlocked). Admins can move into any group; organizers
  #    can only move into groups they've unlocked or created.
  def handle_event("set_group", %{"group_id" => raw}, socket) do
    require_can_edit!(socket)
    group_id = parse_group_id(raw)

    if reachable_group?(socket, group_id) do
      case Events.set_group(socket.assigns.event, group_id) do
        {:ok, event} ->
          message =
            if is_nil(group_id), do: "Rolê removido do grupo.", else: "Rolê movido pro grupo."

          {:noreply,
           socket
           |> put_flash(:info, message)
           |> assign_event(event)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Não deu pra mover: #{inspect(reason)}")}
      end
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Você não tem acesso a esse grupo. Desbloqueie o grupo antes de mover."
       )}
    end
  end

  def handle_event("set_created_by", %{"user_id" => raw}, socket) do
    require_admin!(socket)
    user_id = parse_group_id(raw)

    case Events.set_created_by(socket.assigns.event, user_id) do
      {:ok, event} ->
        message =
          if is_nil(user_id),
            do: "Dono removido — só admin ou token administra agora.",
            else: "Dono atualizado."

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign_event(event)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Não deu pra atualizar o dono: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", _params, socket) do
    require_admin!(socket)
    :ok = Events.delete(socket.assigns.event)

    {:noreply,
     socket
     |> put_flash(:info, "Rolezinho apagado.")
     |> push_navigate(to: ~p"/admin")}
  end

  # Whether the caller can move the event INTO the given group id.
  # `nil` (un-group) is always allowed for an editor; a positive id is
  # only reachable when the caller is admin OR has edit access on that
  # specific group. Kept next to the `set_group` handler so the two
  # rules are obviously the same rule.
  defp reachable_group?(_socket, nil), do: true

  defp reachable_group?(socket, id) when is_integer(id) do
    if socket.assigns[:current_admin?] == true do
      true
    else
      case Groups.get(id) do
        %Group{} = group ->
          Group.editable_by?(
            group,
            false,
            socket.assigns[:unlocked_groups] || MapSet.new(),
            socket.assigns[:current_user_id]
          )

        _ ->
          false
      end
    end
  end

  # Server-side permission asserts. Mirror the template's `:if` gates —
  # they exist because a template gate is not authentication (a hostile
  # client can push any event over the socket). Raise rather than
  # returning a graceful error: reaching these with the wrong role
  # means the client fabricated the event and there's nothing polite to
  # say back.
  defp require_can_edit!(socket) do
    unless Policy.can_edit?(socket.assigns.event, policy_opts(socket, socket.assigns.event)) do
      raise "unauthorized: not an editor of this event"
    end

    :ok
  end

  defp require_admin!(socket) do
    unless socket.assigns[:current_admin?] == true do
      raise "unauthorized: admin required"
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_admin?={@current_admin?}
      page_title={@page_title}
    >
      <header class="mb-5 flex items-center gap-2">
        <.link
          navigate={~p"/r/#{@event.slug}"}
          class="grid size-11 shrink-0 place-items-center rounded-full bg-ink/[0.06] text-ink"
          aria-label="Voltar pro rolê"
        >
          <.icon name="tabler-arrow-left" class="size-[18px]" />
        </.link>
        <div class="min-w-0">
          <h1 class="text-2xl font-extrabold tracking-tight">Editar</h1>
          <p class="truncate font-mono text-[11px] text-muted">
            /r/{@event.slug} · {@event.status}
          </p>
        </div>
      </header>

      <!--
        One card, one save button, for every text/textarea/date field on the
        event. Slug rename is included — the handler renames the URL first
        when it changed and then applies the rest in a single changeset via
        `Events.update_full_details/2`. The controls that are not text-
        shaped (capacity, status, group, owner, delete) stay in their own
        sections below because merging them here would mix "typing prose"
        with "pushing a state button".
      -->
      <section class="rounded-card border border-hairline bg-base-100 p-4 shadow-card mb-3">
        <h2 class="text-[13px] font-extrabold mb-3">Detalhes do rolê</h2>
        <p class="text-[11px] leading-relaxed text-muted mb-4">
          Tudo o que se escreve, num só formulário. Datas no fuso de Brasília
          (BRT). Deixe em branco o que não se aplica.
        </p>

        <.form
          for={@details_form}
          id="details-form"
          phx-submit="save_details"
          phx-change="validate_details"
          class="space-y-4"
        >
          <.input
            field={@details_form[:title]}
            label="Título"
            placeholder="ex.: Vôlei ver-o-beach"
            maxlength="80"
            required
          />
          <.input
            field={@details_form[:description]}
            type="textarea"
            label="Descrição"
            rows="2"
            data-autogrow
            placeholder="O que levar, onde estacionar, qualquer coisa que ajude."
          />
          <p class="-mt-2 text-[11px] text-muted">
            Dá pra usar <code class="font-mono font-bold">*negrito*</code>,
            <code class="font-mono italic">_itálico_</code>
            e <code class="font-mono line-through">~riscado~</code>, como no WhatsApp.
          </p>

          <!--
            Same free-form + datalist pattern as the create form: any string
            still goes through, the four defaults are hints, not a constraint.
          -->
          <.input
            field={@details_form[:category]}
            label="Categoria"
            placeholder="ex.: Trabalho, Esportes"
            list="event-category-suggestions"
          />
          <datalist id="event-category-suggestions">
            <option :for={suggestion <- category_suggestions()} value={suggestion} />
          </datalist>

          <.input field={@details_form[:local]} label="Local" placeholder="ex.: Rua Caripunas" />

          <div class="grid grid-cols-2 gap-4">
            <.input field={@details_form[:date]} type="date" label="Data (BRT)" />
            <.input field={@details_form[:time]} type="time" label="Horário (BRT)" />
          </div>

          <.split_method_fields form={@details_form} />
          <!--
            Mirror comment from `EventNewLive`: this is not a password. The
            four data-attrs plus `autocomplete="off"` opt out of every
            mainstream password manager — without them Bitwarden autofills
            the Pix key with the user's stored password.
          -->
          <!--
            Type first, then the key — the choice frames what the field is
            for and avoids the ambiguous-11-digit bug (a bare mobile phone
            used to be guessed as CPF).
          -->
          <.input
            field={@details_form[:pix_key_type]}
            type="select"
            label="Tipo da chave"
            prompt="Escolha o tipo"
            options={
              Enum.map(Rolezinho.Pix.types(), fn t ->
                {Rolezinho.Pix.type_label(t), Atom.to_string(t)}
              end)
            }
          />
          <.input
            field={@details_form[:pix_key]}
            label="Chave Pix"
            placeholder="telefone, CPF, e-mail ou aleatória"
            autocomplete="off"
            data-1p-ignore="true"
            data-lpignore="true"
            data-bwignore="true"
            data-form-type="other"
          />

          <.input
            field={@details_form[:password]}
            label="Senha (opcional)"
            placeholder="em branco = sem senha"
            autocomplete="off"
            data-1p-ignore="true"
            data-lpignore="true"
            data-bwignore="true"
          />
          <p :if={@event.password} class="-mt-2 text-[11px] leading-relaxed text-muted">
            Senha atual:
            <code class="font-mono text-base-content bg-base-200 px-1 py-0.5 rounded">{@event.password}</code>
          </p>

          <label class="block">
            <span class="label text-sm mb-1">Link</span>
            <div class="inline-flex -space-x-px w-full">
              <span class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium px-3 py-1.5 rounded-none first:rounded-l-md last:rounded-r-md pointer-events-none font-mono text-xs sm:text-sm">/r/</span>
              <input
                type="text"
                name="details[slug]"
                id="details_slug"
                value={@details_form[:slug].value}
                phx-hook=".SlugFlash"
                class={[
                  field_class(),
                  "rounded-none first:rounded-l-md last:rounded-r-md flex-1 font-mono"
                ]}
                pattern="[a-z0-9](?:[a-z0-9-]{0,60}[a-z0-9])?"
                required
              />
            </div>
            <p class="mt-1 text-[11px] text-muted">
              Trocar o link muda a URL do rolezinho. Links antigos deixam de funcionar.
            </p>
          </label>
          <div class="pt-1">
            <button
              type="submit"
              class="rounded-cta bg-ink px-4 py-3 text-[13px] font-bold text-ink-content shadow-cta transition-transform active:scale-[.97]"
            >
              Salvar
            </button>
          </div>
        </.form>

        <!--
          Colocated hook fires the accent-tint flash on the slug input every
          time the server pushes a `slug-retagged` event. The animation only
          plays if the slug field is not the active element — that guards
          against flashing while the user is typing in it themselves.
        -->
        <script :type={Phoenix.LiveView.ColocatedHook} name=".SlugFlash">
          export default {
            mounted() {
              this.handleEvent("slug-retagged", ({ slug }) => {
                if (document.activeElement === this.el) return
                if (typeof slug === "string" && slug !== this.el.value) {
                  this.el.value = slug
                }
                // Restart the animation: remove the class, force a reflow,
                // then add it back. Without the reflow, adding a class that
                // is already present is a no-op and the animation would only
                // play the first time.
                this.el.classList.remove("animate-flash-accent")
                void this.el.offsetWidth
                this.el.classList.add("animate-flash-accent")
              })
            }
          }
        </script>
      </section>

      <section class="rounded-card border border-hairline bg-base-100 p-4 shadow-card mb-3">
        <h2 class="text-[13px] font-extrabold mb-3">Vagas</h2>
        <form phx-submit="resize_lists" id="resize-form" class="space-y-3">
          <div class="grid grid-cols-2 gap-2">
            <.input
              type="number"
              name="main_size"
              id="main-size-input"
              value={@main_size_input}
              min="1"
              max="500"
              label="Na lista"
            />
            <.input
              type="number"
              name="wait_size"
              id="wait-size-input"
              value={@wait_size_input}
              min="0"
              max="100"
              label="Na espera"
            />
          </div>
          <p class="text-[11px] text-muted">
            0 na espera desliga a fila. Não é possível reduzir a lista abaixo
            de quantas pessoas já estão nela. Atualmente: {filled_count(@event)}.
          </p>
          <div>
            <button
              type="submit"
              class="rounded-row bg-ink px-4 py-2.5 text-xs font-bold text-ink-content transition-transform active:scale-[.97] disabled:opacity-40 disabled:pointer-events-none"
            >
              Atualizar
            </button>
          </div>
        </form>
      </section>

      <.link
        navigate={~p"/admin/r/#{@event.slug}/formulario"}
        class="mb-3 flex items-center gap-2.5 rounded-card border border-hairline bg-base-100 p-4 shadow-card"
      >
        <div class="min-w-0 flex-1">
          <div class="text-[13px] font-bold">Formulário de entrada</div>
          <div class="mt-0.5 text-[11px] text-muted">O que a pessoa preenche pra entrar</div>
        </div>
        <.icon name="tabler-chevron-right" class="size-4 shrink-0 text-ink/30" />
      </.link>

      <section class="rounded-card border border-hairline bg-base-100 p-4 shadow-card mb-3">
        <h2 class="text-[13px] font-extrabold mb-3">Status</h2>
        <!-- Current state lives in aria-checked rather than a conditional class,
             so the styling follows the attribute and a screen reader hears which
             one is selected. -->
        <div class="flex flex-wrap gap-1.5" role="radiogroup" aria-label="Status do rolê">
          <button
            :for={status <- [:active, :maybe, :payments_only, :done]}
            type="button"
            role="radio"
            aria-checked={to_string(@event.status == status)}
            phx-click="set_status"
            phx-value-status={to_string(status)}
            class={[
              "rounded-row bg-ink/[0.08] px-3.5 py-2.5 text-xs font-bold text-muted",
              "aria-checked:bg-ink aria-checked:text-ink-content",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
            ]}
          >
            {status_label(status)}
          </button>
        </div>
        <!-- A definition list, not a paragraph: four states running together in
             prose meant the only thing separating one from the next was where the
             bold stopped, and choosing a status means comparing them. One per
             line, so scanning down the terms is enough. -->
        <dl class="mt-3 space-y-1.5 text-[11px] leading-relaxed text-muted">
          <div
            :for={status <- [:active, :maybe, :payments_only, :done]}
            class="flex gap-1.5"
          >
            <dt class="shrink-0 font-bold">{status_label(status)}:</dt>
            <dd class="flex-1">{status_description(status)}</dd>
          </div>
        </dl>

        <!--
          Visibility is orthogonal to status: an active rolê can be occult
          (link-only), a payments-only one can too, and so on. Rendered as
          a checkbox next to the status radio so the two axes read as what
          they are — two independent decisions.
        -->
        <label class="mt-4 flex items-center gap-2 text-[13px]">
          <input
            type="checkbox"
            phx-click="toggle_hidden"
            checked={@event.hidden}
            aria-label="Ocultar da home"
            class="size-4 rounded border-ink/30 text-accent focus:ring-accent"
          />
          <span class="font-bold">Oculto</span>
          <span class="text-[11px] text-muted">não aparece na home, só pelo link.</span>
        </label>
      </section>

      <!--
        Admin-only sections below: owner reassignment, group move, and
        the destructive delete. Everything above this line is fair game
        for the event's organizer too. The template gate is a companion
        to the server-side `require_admin!/1` in each handler — the
        template just stops rendering the controls a non-admin editor
        would not be able to use anyway.
      -->
      <section
        :if={@current_admin?}
        class="rounded-card border border-hairline bg-base-100 p-4 shadow-card mb-3"
      >
        <h2 class="text-[13px] font-extrabold mb-3">Dono do rolê</h2>
        <p class="text-[11px] text-muted mb-3">
          Quem criou o rolê logado com GitHub. Um dono pode administrar em
          qualquer aparelho depois de logar (ADR-0002). Só admin muda.
        </p>

        <form phx-change="set_created_by" id="creator-form" class="flex flex-wrap items-end gap-3">
          <label class="flex-1 min-w-64">
            <span class="label text-sm mb-1">Dono</span>
            <select
              name="user_id"
              id="event-creator-select"
              class={[field_class(), "w-full"]}
            >
              <option value="" selected={is_nil(@event.created_by_user_id)}>Sem dono</option>
              <option
                :for={user <- @users}
                value={user.id}
                selected={@event.created_by_user_id == user.id}
              >
                @{user.github_login}
              </option>
            </select>
          </label>
        </form>
      </section>

      <section class="rounded-card border border-hairline bg-base-100 p-4 shadow-card mb-3">
        <h2 class="text-[13px] font-extrabold mb-3">Grupo</h2>
        <p class="text-[11px] text-muted mb-3">
          Mover esse rolê pra outro grupo (ou pra fora de qualquer grupo). Você
          só vê os grupos que você criou ou desbloqueou; admin vê todos.
          Tirar do grupo atual funciona sempre.
        </p>

        <form phx-change="set_group" id="group-form" class="flex flex-wrap items-end gap-3">
          <label class="flex-1 min-w-64">
            <span class="label text-sm mb-1">Grupo</span>
            <select
              name="group_id"
              id="event-group-select"
              class={[field_class(), "w-full"]}
            >
              <option value="" selected={is_nil(@event.group_id)}>Nenhum</option>
              <option
                :for={group <- @groups}
                value={group.id}
                selected={@event.group_id == group.id}
              >
                {group.name} (/g/{group.slug})
              </option>
            </select>
          </label>
        </form>
      </section>

      <section :if={@current_admin?} class="rounded-2xl border border-error/40 bg-error/5 p-5">
        <h2 class="font-semibold text-error mb-2">Zona perigosa</h2>
        <p class="text-sm text-base-content/70 mb-3">
          Apagar remove o arquivo permanentemente. Não dá pra desfazer.
        </p>
        <button
          type="button"
          phx-click="delete"
          data-confirm="Apagar este rolezinho? Isso é permanente."
          class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:pointer-events-none px-4 py-2 text-sm bg-error text-error-content hover:bg-error/90 px-3 py-1.5"
        >
          Apagar rolezinho
        </button>
      </section>
    </Layouts.app>
    """
  end

  defp parse_int_in_range(raw, min, max) do
    case Integer.parse(String.trim(to_string(raw))) do
      {n, ""} when n >= min and n <= max -> {:ok, n}
      _ -> {:error, :invalid_range}
    end
  end

  # `rename_slug/2` no-ops when the slug is unchanged, so we could always
  # call it — but the explicit guard makes the flow readable and avoids the
  # broadcast a rename would fire.
  defp rename_if_changed(%Event{slug: same} = event, same), do: {:ok, event}
  defp rename_if_changed(%Event{} = event, ""), do: {:ok, event}
  defp rename_if_changed(%Event{} = event, new_slug), do: Events.rename_slug(event, new_slug)

  # If the user hasn't touched the slug and the current slug tail matches
  # the reference date, swap the tail for the new date and remember the new
  # reference. Any other case is a no-op on the socket state.
  defp retag_on_date_change(socket, params) do
    if socket.assigns.slug_touched? do
      socket
    else
      current_slug = params |> Map.get("slug", "") |> to_string() |> String.trim()
      new_date = parse_date(params["date"])
      reference_date = socket.assigns.slug_reference_date

      case retag_slug_with_date(current_slug, reference_date, new_date) do
        ^current_slug ->
          # No pattern match or dates were nil/equal — leave state as is.
          socket

        retagged ->
          socket
          |> assign(:slug_reference_date, new_date)
          # The hook picks this up and briefly flashes the slug input to say
          # "the URL just moved with the date".
          |> push_event("slug-retagged", %{slug: retagged})
          |> put_slug_in_form(retagged)
      end
    end
  end

  defp put_slug_in_form(socket, new_slug) do
    form = socket.assigns.details_form
    updated_params = Map.put(form.params, "slug", new_slug)
    assign(socket, :details_form, to_form(updated_params, as: :details))
  end

  # Submit-time retag. Only kicks in when the user did NOT touch the slug
  # themselves. The live `phx-change` retag above is the main path; this
  # runs when phx-change never fired (JS off / stale reconnect).
  defp maybe_retag_slug_with_date(%Event{slug: current_slug} = event, current_slug, params) do
    retag_slug_with_date(current_slug, extract_current_date(event), parse_date(params["date"]))
  end

  defp maybe_retag_slug_with_date(_event, submitted_slug, _params), do: submitted_slug

  defp extract_current_date(%Event{} = event) do
    {meta, _} = Meta.extract(event.header)
    meta.date
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  # Rewrites the trailing date tag on `current_slug` when it matches the
  # current event's date. Handles two shapes:
  #
  #   * `<base>-DD-MM`             — the auto-slugify tag from `EventNewLive`.
  #     Swaps for the new `-DD-MM`.
  #   * `<base>-DD-MM-clonado`     — the same tag under a clone, which
  #     `Events.clone/1` appends via `unique_clone_slug/1`. The `-clonado`
  #     tail was a slug-uniqueness workaround at clone time; the moment the
  #     organizer moves the date, the URL is about a different event on a
  #     different day, so we drop `-clonado` and land on just `<base>-DD-MM`.
  #
  # Anything else — no pattern, a `-DD-MM` that does not match the current
  # date, missing dates on either side — returns the slug unchanged.
  defp retag_slug_with_date(current_slug, nil, _new_date), do: current_slug
  defp retag_slug_with_date(current_slug, _current_date, nil), do: current_slug

  defp retag_slug_with_date(current_slug, %Date{} = same, %Date{} = same), do: current_slug

  defp retag_slug_with_date(current_slug, %Date{} = current_date, %Date{} = new_date) do
    current_tag = "-" <> pad2(current_date.day) <> "-" <> pad2(current_date.month)
    new_tag = "-" <> pad2(new_date.day) <> "-" <> pad2(new_date.month)

    clonado_current = current_tag <> "-clonado"

    cond do
      String.ends_with?(current_slug, clonado_current) ->
        strip_suffix(current_slug, clonado_current) <> new_tag

      String.ends_with?(current_slug, current_tag) ->
        strip_suffix(current_slug, current_tag) <> new_tag

      true ->
        current_slug
    end
  end

  # Slugs are ASCII-only, so grapheme length == byte length; using
  # `String.split_at/2` keeps the code obvious.
  defp strip_suffix(str, suffix) do
    keep = String.length(str) - String.length(suffix)
    {base, _} = String.split_at(str, keep)
    base
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp status_description(:active), do: "aparece na página inicial e aceita novas inscrições."

  defp status_description(:maybe),
    do:
      "aparece na home marcado como tentativo — aceita inscrições, mas o rolê ainda pode não rolar."

  defp status_description(:payments_only),
    do: "aparece na home, mas ninguém entra em novas listas — o admin só marca quem pagou."

  defp status_description(:done), do: "arquivado, apenas o admin acessa."

  defp status_label(:active), do: "Ativo"
  defp status_label(:maybe), do: "Averiguando Resenha"
  defp status_label(:payments_only), do: "Só pagamentos"
  defp status_label(:done), do: "Concluído"

  # Turns the context's error shape (`%{field => [msg | _]}`) into what
  # `to_form(errors: ...)` wants (`[{field, {msg, []}}]`). Only the first
  # message per field is surfaced; the others are shadowed until the top
  # one is resolved, which is the ergonomics Phoenix's own `<.input>`
  # follows for error rendering.
  defp to_form_errors(errors) when is_map(errors) do
    for {field, [msg | _]} <- errors, do: {field, {msg, []}}
  end

  # Picks a helpful flash for the *common* validation failures so the
  # message says what to do rather than dumping the raw error map. Any
  # unknown field falls back to a generic prompt — the inline errors
  # under the fields still tell the full story.
  defp flash_for_field_errors(%{pix_key_type: _}),
    do: "Escolha o tipo da chave Pix pra continuar."

  defp flash_for_field_errors(%{pix_key: [msg | _]}),
    do: "Chave Pix: #{msg}"

  defp flash_for_field_errors(_),
    do: "Revisa os campos destacados e tenta de novo."

  # An empty string is how the <select> represents "no group".
  defp parse_group_id(""), do: nil
  defp parse_group_id(nil), do: nil

  defp parse_group_id(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_group_id(id) when is_integer(id), do: id

  defp filled_count(%Event{main_list: list}) do
    Enum.count(list, fn a -> String.trim(a.name) != "" end)
  end
end
