defmodule RolezinhoWeb.GroupLive do
  @moduledoc """
  Public group page.

  Behaviour by role, and by whether the group has a password:

    * Password-protected + not admin + not unlocked → renders **only** the
      unlock panel. No group name, no event list, no crumb, no chrome. The
      page must not leak anything about the group before the password lands
      (SECURITY.md §3).

    * Otherwise → shows the group name, the event list (active +
      payments_only, group's own events only, hidden events excluded), and
      an inline edit surface when the caller may edit (admin always;
      unlocked non-admin only on password-protected groups).
  """
  use RolezinhoWeb, :live_view

  alias Rolezinho.Group
  alias Rolezinho.Groups
  alias Rolezinho.Notifications
  alias RolezinhoWeb.Components.UI.BottomSheet

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Groups.find(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Grupo não encontrado.")
         |> push_navigate(to: ~p"/")}

      group ->
        if connected?(socket), do: Groups.subscribe(slug)

        {:ok,
         socket
         |> assign(:page_title, page_title_for(group, socket))
         |> assign_group(group)
         |> assign(:name_input, group.name)
         |> assign(:password_input, group.password || "")}
    end
  end

  # Rebuild derived assigns after the group changes (edit, PubSub broadcast).
  defp assign_group(socket, %Group{} = group) do
    accessible? =
      Group.accessible?(
        group,
        socket.assigns.current_admin?,
        socket.assigns.unlocked_groups,
        socket.assigns[:current_user_id]
      )

    editable? =
      Group.editable_by?(
        group,
        socket.assigns.current_admin?,
        socket.assigns.unlocked_groups,
        socket.assigns[:current_user_id]
      )

    # Hidden events on the group page: shown only to the admin and
    # the group's own creator. An unlocked-but-not-owning visitor,
    # even one holding the group password, keeps the old behaviour
    # — they see the public event list, and hidden events stay
    # reachable only by direct URL (same rule as the home page).
    #
    # `Group.owned_by?/3` is deliberately narrower than
    # `editable_by?/4` for exactly this call site: an unlocked-only
    # visitor may edit, but should not see what the owner chose to
    # hide.
    owner? =
      Group.owned_by?(
        group,
        socket.assigns.current_admin?,
        socket.assigns[:current_user_id]
      )

    events =
      cond do
        not accessible? -> []
        owner? -> Groups.list_events(group, visibility: :with_hidden)
        true -> Groups.list_events(group, visibility: :public)
      end

    socket
    |> assign(:group, group)
    |> assign(:accessible?, accessible?)
    |> assign(:editable?, editable?)
    |> assign(:owner?, owner?)
    |> assign(:password_protected?, Group.password_protected?(group))
    |> assign(:events, events)
    |> assign(:page_title, page_title_for(group, socket))
    |> assign(:following?, Notifications.following?(socket.assigns[:current_user_id], group.id))
  end

  defp page_title_for(%Group{} = group, socket) do
    if Group.accessible?(group, socket.assigns.current_admin?, socket.assigns.unlocked_groups) do
      group.name
    else
      # Never leak the name through the tab title on a locked group.
      "Grupo protegido"
    end
  end

  @impl true
  def handle_info({:updated, %Group{} = group}, socket) do
    {:noreply, socket |> assign_group(group) |> assign(:name_input, group.name)}
  end

  def handle_info({:deleted, _group}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "O grupo foi apagado.")
     |> push_navigate(to: ~p"/")}
  end

  @impl true
  # The bell. The hook only sends this after the browser granted permission
  # and produced a push subscription; the server still re-checks that someone
  # is signed in and can open the group (`Notifications.follow/3`).
  def handle_event("push_follow", %{"subscription" => %{} = subscription} = params, socket) do
    case socket.assigns[:current_user] do
      %Rolezinho.Accounts.User{} = user ->
        with {:ok, _device} <-
               Notifications.register_device(user, subscription, params["user_agent"]),
             {:ok, _follow} <-
               Notifications.follow(user, socket.assigns.group,
                 admin?: socket.assigns.current_admin?,
                 unlocked_groups: socket.assigns.unlocked_groups
               ) do
          {:noreply,
           socket
           |> assign(:following?, true)
           |> put_flash(:info, "Pronto! Você vai receber um aviso quando sair rolê novo aqui.")}
        else
          _error ->
            {:noreply, put_flash(socket, :error, "Não deu pra ativar os avisos neste aparelho.")}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("push_unfollow", _params, socket) do
    case socket.assigns[:current_user] do
      %Rolezinho.Accounts.User{} = user ->
        :ok = Notifications.unfollow(user, socket.assigns.group)

        {:noreply,
         socket
         |> assign(:following?, false)
         |> put_flash(:info, "Avisos desse grupo desligados.")}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("update_name_input", %{"name" => name}, socket) do
    {:noreply, assign(socket, :name_input, name)}
  end

  def handle_event("save_name", %{"name" => name}, socket) do
    require_edit!(socket)

    case Groups.update_name(socket.assigns.group, name) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Nome atualizado.")
         |> assign_group(group)
         |> assign(:name_input, group.name)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Não deu pra salvar. Confira o nome.")}
    end
  end

  def handle_event("update_password_input", %{"password" => password}, socket) do
    {:noreply, assign(socket, :password_input, password)}
  end

  def handle_event("save_password", %{"password" => password}, socket) do
    require_edit!(socket)

    case Groups.update_password(socket.assigns.group, password) do
      {:ok, group} ->
        message =
          if Group.password_protected?(group),
            do: "Senha atualizada.",
            else: "Senha removida."

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign_group(group)
         |> assign(:password_input, group.password || "")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Não deu pra salvar a senha.")}
    end
  end

  # The template hides these controls when the caller cannot edit, but a socket
  # message can be forged, so the handler re-checks (SECURITY.md §2).
  defp require_edit!(socket) do
    unless socket.assigns.editable? do
      raise "unauthorized"
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_admin?={@current_admin?}
      current_user={@current_user}
      page_title={@page_title}
    >
      <%= if not @accessible? do %>
        <.locked_panel slug={@group.slug} />
      <% else %>
        <.group_view
          group={@group}
          events={@events}
          editable?={@editable?}
          password_protected?={@password_protected?}
          current_admin?={@current_admin?}
          name_input={@name_input}
          password_input={@password_input}
          current_user={@current_user}
          following?={@following?}
        />
        <.push_sheets group={@group} />
      <% end %>
    </Layouts.app>
    """
  end

  # ---------- Locked panel ----------

  # The whole page when the visitor has not unlocked. Deliberately mirrors the
  # event unlock panel (`RolezinhoWeb.EventLive.unlock_panel/1`) — same words,
  # same shape — but with nothing about the group leaking through: no name,
  # no chrome, no back link into anything specific.
  attr :slug, :string, required: true

  defp locked_panel(assigns) do
    ~H"""
    <section class="mx-auto max-w-[420px] px-2 py-6 text-center">
      <div class="mx-auto grid size-16 place-items-center rounded-[22px] bg-ink">
        <.icon name="tabler-lock" class="size-7 text-accent" />
      </div>

      <p class="mt-5 text-[11px] font-bold uppercase tracking-wide text-accent">
        Convite recebido
      </p>
      <h2 class="mt-2 text-2xl font-extrabold leading-tight tracking-tight">
        Esse grupo é<br />protegido por senha
      </h2>
      <p class="mt-3 text-sm leading-relaxed text-muted">
        Digite a senha que veio junto com o link pra ver os rolês.
      </p>

      <form
        method="post"
        action={~p"/g/#{@slug}/unlock"}
        id={"group-unlock-form-" <> @slug}
        class="mt-6 rounded-[20px] border border-hairline bg-base-100 p-4 text-left shadow-card"
      >
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <label class="block">
          <span class="text-[11px] font-bold uppercase tracking-wide text-muted">
            Senha do grupo
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
          Ver o grupo
        </button>
      </form>

      <p class="mt-3.5 text-xs text-muted">
        Não tem a senha? Pede pra quem te chamou.
      </p>
    </section>
    """
  end

  # ---------- Unlocked view ----------

  attr :group, :map, required: true
  attr :events, :list, required: true
  attr :editable?, :boolean, required: true
  attr :password_protected?, :boolean, required: true
  attr :current_admin?, :boolean, required: true
  attr :name_input, :string, required: true
  attr :password_input, :string, required: true
  attr :current_user, :any, default: nil
  attr :following?, :boolean, default: false

  defp group_view(assigns) do
    ~H"""
    <article class="space-y-6">
      <header class="space-y-3">
        <div class="flex items-center gap-2 text-xs text-base-content/50">
          <.link navigate={~p"/"} class="hover:text-base-content">← Home</.link>
          <span>·</span>
          <span>/g/{@group.slug}</span>
          <span
            :if={@group.visibility == :hidden}
            class="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium bg-warning/15 text-warning"
          >
            Oculto
          </span>
          <!--
            If we're rendering this header at all, the caller cleared the
            gate (see the locked_panel branch above). So on a password-
            protected group the badge always reads "com acesso" here and
            uses the accent (green) tone. Kept the pill separate from the
            general “com senha” copy elsewhere — that's descriptive, this
            is a live status.
          -->
          <span
            :if={@group.password}
            class="inline-flex items-center rounded-full border border-success/30 bg-success/10 px-2 py-0.5 text-xs font-medium text-success"
          >
            Com acesso
          </span>
        </div>

        <div class="flex items-start justify-between gap-3">
          <h1 class="min-w-0 flex-1 text-2xl font-extrabold tracking-tight">{@group.name}</h1>
          <div class="flex shrink-0 items-center gap-1.5">
            <.push_bell current_user={@current_user} following?={@following?} />
            <.link
              :if={@current_admin?}
              navigate={~p"/admin/g/#{@group.slug}/edit"}
              class="grid size-11 place-items-center rounded-full bg-ink/[0.06] text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
              aria-label="Editar o grupo (admin)"
            >
              <.icon name="tabler-settings" class="size-[18px]" />
            </.link>
          </div>
        </div>

        <p
          :if={not @editable? and not @password_protected?}
          class="text-[11px] leading-relaxed text-muted"
        >
          Esse grupo não tem senha, então só o admin da plataforma pode editar ou
          adicionar rolês. Peça pro admin definir uma senha se quiser gerenciar.
        </p>
      </header>

      <section class="rounded-card border border-hairline bg-base-100 p-4 shadow-card">
        <div class="mb-3 flex items-center justify-between">
          <h2 class="text-[13px] font-extrabold">Rolês do grupo</h2>
          <.link
            :if={@editable?}
            navigate={~p"/criar?group=#{@group.slug}"}
            class="rounded-row bg-ink px-3 py-1.5 text-xs font-bold text-ink-content"
          >
            Novo rolê
          </.link>
        </div>

        <.empty_state :if={@events == []} icon="tabler-diamond" title="Nenhum rolê ainda">
          <%= if @editable? do %>
            Cria o primeiro rolê pra galera entrar.
          <% else %>
            Assim que rolês forem adicionados, eles aparecem aqui.
          <% end %>
        </.empty_state>

        <ul :if={@events != []} class="grid grid-cols-1 gap-2.5 md:grid-cols-2 xl:grid-cols-3">
          <li :for={event <- @events}>
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
              navigate={~p"/r/#{event.slug}"}
            />
          </li>
        </ul>
      </section>

      <section
        :if={@editable?}
        class="rounded-card border border-hairline bg-base-100 p-4 shadow-card sm:max-w-[36rem]"
      >
        <h2 class="text-[13px] font-extrabold mb-3">Nome do grupo</h2>
        <form
          phx-submit="save_name"
          phx-change="update_name_input"
          id="group-name-form"
          class="flex flex-wrap items-end gap-3"
        >
          <label class="flex-1 min-w-64">
            <span class="label text-sm mb-1">Nome</span>
            <input
              type="text"
              name="name"
              id="group-name-input"
              value={@name_input}
              maxlength="80"
              minlength="3"
              class={[
                RolezinhoWeb.CoreComponents.field_class(),
                "w-full"
              ]}
              required
            />
          </label>
          <button
            type="submit"
            class="rounded-row bg-ink px-4 py-2.5 text-xs font-bold text-ink-content transition-transform active:scale-[.97] disabled:opacity-40 disabled:pointer-events-none"
            disabled={String.trim(@name_input) == @group.name}
          >
            Salvar
          </button>
        </form>
      </section>

      <section
        :if={@editable? and @password_protected?}
        class="rounded-card border border-hairline bg-base-100 p-4 shadow-card sm:max-w-[36rem]"
      >
        <h2 class="text-[13px] font-extrabold mb-3">Senha do grupo</h2>
        <p class="text-[11px] text-muted mb-3">
          A senha é o que te deixa editar o grupo e adicionar rolês depois. Se
          removida, só o admin da plataforma consegue editar.
        </p>

        <form
          phx-submit="save_password"
          phx-change="update_password_input"
          id="group-password-form"
          class="flex flex-wrap items-end gap-3"
        >
          <label class="flex-1 min-w-64">
            <span class="label text-sm mb-1">Senha</span>
            <input
              type="text"
              name="password"
              id="group-password-input"
              value={@password_input}
              placeholder="em branco = remover senha"
              class={[
                RolezinhoWeb.CoreComponents.field_class(),
                "w-full font-mono"
              ]}
              autocomplete="off"
            />
          </label>
          <button
            type="submit"
            class="rounded-row bg-ink px-4 py-2.5 text-xs font-bold text-ink-content transition-transform active:scale-[.97] disabled:opacity-40 disabled:pointer-events-none"
            disabled={@password_input == (@group.password || "")}
          >
            Salvar senha
          </button>
        </form>

        <p :if={@group.password} class="text-[11px] leading-relaxed text-muted mt-3">
          Senha atual:
          <code class="font-mono text-base-content bg-base-200 px-1 py-0.5 rounded">{@group.password}</code>
        </p>
      </section>
    </article>
    """
  end

  # ---------- Small helpers, copied from HomeLive so the group page shows the
  # same information for each event card. ----------

  defp status_for(%Rolezinho.Event{status: :payments_only}), do: "payments_only"
  defp status_for(%Rolezinho.Event{status: :done}), do: "done"
  defp status_for(%Rolezinho.Event{status: :maybe}), do: "maybe"

  defp status_for(%Rolezinho.Event{} = event) do
    if Rolezinho.Event.main_full?(event), do: "full", else: "open"
  end

  # Same tooltip pattern as HomeLive — only "maybe" carries a hint.
  defp status_hint(%Rolezinho.Event{status: :maybe}), do: Rolezinho.Event.maybe_status_hint()
  defp status_hint(%Rolezinho.Event{}), do: nil

  defp when_text(%Rolezinho.Event{starts_at: nil}), do: nil

  defp when_text(%Rolezinho.Event{starts_at: starts_at}) do
    starts_at
    |> DateTime.add(-3 * 3600, :second)
    |> Calendar.strftime("%d/%m · %Hh")
  end

  defp filled_count(%Rolezinho.Event{main_list: list}) do
    Enum.count(list, &(String.trim(&1.name) != ""))
  end

  defp attendee_names(%Rolezinho.Event{main_list: list}) do
    list
    |> Enum.map(&String.trim(&1.name))
    |> Enum.reject(&(&1 == ""))
  end

  # The bell next to the group's name. Anonymous visitors see it too: tapping
  # opens the sign-in sheet, since notifications belong to an account.
  attr :current_user, :any, default: nil
  attr :following?, :boolean, default: false

  defp push_bell(%{current_user: nil} = assigns) do
    ~H"""
    <button
      type="button"
      id="push-bell"
      phx-click={BottomSheet.show("push-login-sheet")}
      class={bell_class(false)}
      aria-label="Receber avisos de rolê novo"
    >
      <.icon name="tabler-bell" class="size-[18px]" />
    </button>
    """
  end

  defp push_bell(assigns) do
    assigns =
      assign(
        assigns,
        :vapid_public_key,
        Application.fetch_env!(:web_push_elixir, :vapid_public_key)
      )

    ~H"""
    <button
      type="button"
      id="push-bell"
      phx-hook=".PushBell"
      data-following={to_string(@following?)}
      data-vapid-key={@vapid_public_key}
      data-ios-hint={BottomSheet.show("push-ios-sheet")}
      data-unavailable-hint={BottomSheet.show("push-unavailable-sheet")}
      class={bell_class(@following?)}
      aria-pressed={to_string(@following?)}
      aria-label={
        if(@following?, do: "Desligar avisos desse grupo", else: "Receber avisos de rolê novo")
      }
    >
      <.icon :if={@following?} name="tabler-bell-ringing-filled" class="size-[18px]" />
      <.icon :if={!@following?} name="tabler-bell" class="size-[18px]" />
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PushBell">
      // Base64url VAPID key -> the Uint8Array PushManager.subscribe() wants.
      const keyBytes = (key) => {
        const padded = (key + "=".repeat((4 - (key.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/")
        return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0))
      }

      export default {
        mounted() {
          this.el.addEventListener("click", () => this.toggle())
        },
        async toggle() {
          if (this.el.dataset.following === "true") {
            this.pushEvent("push_unfollow", {})
            return
          }

          // iPhone and iPad only deliver Web Push to an app added to the home
          // screen and opened from there.
          const ios = /iphone|ipad|ipod/i.test(navigator.userAgent)
          const standalone =
            window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true
          if (ios && !standalone) return this.liveSocket.execJS(this.el, this.el.dataset.iosHint)

          const supported = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window
          if (!supported) return this.liveSocket.execJS(this.el, this.el.dataset.unavailableHint)

          try {
            // Asked first, while still inside the tap: browsers only show the
            // permission prompt in response to a user gesture.
            const permission = await Notification.requestPermission()
            if (permission !== "granted") return this.liveSocket.execJS(this.el, this.el.dataset.unavailableHint)

            const registration = await navigator.serviceWorker.register("/sw.js")
            await navigator.serviceWorker.ready
            const subscription =
              (await registration.pushManager.getSubscription()) ||
              (await registration.pushManager.subscribe({
                userVisibleOnly: true,
                applicationServerKey: keyBytes(this.el.dataset.vapidKey),
              }))

            this.pushEvent("push_follow", {
              subscription: subscription.toJSON(),
              user_agent: navigator.userAgent.slice(0, 255),
            })
          } catch (_) {
            this.liveSocket.execJS(this.el, this.el.dataset.unavailableHint)
          }
        },
      }
    </script>
    """
  end

  defp bell_class(following?) do
    [
      "grid size-11 place-items-center rounded-full focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
      if(following?, do: "bg-info text-info-content", else: "bg-ink/[0.06] text-ink")
    ]
  end

  attr :group, :map, required: true

  defp push_sheets(assigns) do
    ~H"""
    <.bottom_sheet
      id="push-login-sheet"
      title="Entre pra receber avisos"
      description="Quando sair rolê novo nesse grupo, a gente te avisa no celular — mesmo com o app fechado. Pra isso, entra na sua conta."
    >
      <div class="space-y-2">
        <a
          id="push-login-github"
          href={"/auth/github?" <> URI.encode_query(return_to: ~p"/g/#{@group.slug}")}
          class="flex w-full items-center justify-center gap-2 rounded-cta bg-ink px-4 py-3.5 text-[14px] font-bold text-ink-content"
        >
          <.icon name="tabler-brand-github" class="size-[18px]" /> Entrar com GitHub
        </a>
        <.link
          id="push-login-email"
          navigate={~p"/entrar?#{[return_to: ~p"/g/#{@group.slug}"]}"}
          class="flex w-full items-center justify-center gap-2 rounded-cta bg-ink/[0.06] px-4 py-3.5 text-[14px] font-bold text-ink"
        >
          <.icon name="tabler-mail" class="size-[18px]" /> Entrar com e-mail
        </.link>
      </div>
    </.bottom_sheet>

    <.bottom_sheet
      id="push-ios-sheet"
      title="Adicione à tela inicial"
      description="No iPhone, os avisos só chegam pelo app na tela inicial."
    >
      <ol class="list-decimal space-y-1.5 pl-5 text-[13px] leading-relaxed">
        <li>
          Toque em
          <.icon name="tabler-square-arrow-up" class="inline-block size-4 align-text-bottom" />
          Compartilhar no Safari.
        </li>
        <li>Escolha <span class="font-semibold">Adicionar à Tela de Início</span>.</li>
        <li>Abra o Rolezinho pelo ícone novo e toque no sininho de novo.</li>
      </ol>
    </.bottom_sheet>

    <.bottom_sheet
      id="push-unavailable-sheet"
      title="Avisos indisponíveis"
      description="Este navegador não permitiu notificações. Libere as notificações do site nas configurações do navegador e toque no sininho de novo."
    />
    """
  end
end
