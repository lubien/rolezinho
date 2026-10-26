defmodule RolezinhoWeb.SettingsLive do
  @moduledoc """
  Personal preferences, kept entirely in the browser.

  Name and phone exist to make the *second* event cost almost nothing: the join
  sheet reads them as defaults, so someone who has joined once does not retype
  their own name in every list. That is the 30-second promise in `PRODUCT.md`
  applied to the returning visitor rather than the first-time one.

  Nothing here is sent to the server, and there is no account to attach it to.
  The values sit in `localStorage` on this device and travel to the server only
  when the person actually joins a list, as part of that event's row. Stated
  plainly on the screen, because a form asking for a phone number owes the
  reader that.
  """
  use RolezinhoWeb, :live_view

  alias Rolezinho.Accounts
  alias Rolezinho.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Suas preferências")
     |> assign(:password_error, nil)
     |> assign(:email_error, nil)}
  end

  # Set (first time) OR change (subsequent) the signed-in user's
  # password. Rendered only when there's a signed-in user; still
  # guarded server-side so a hostile push_event over the socket for
  # an anonymous session is a silent no-op.
  # Sets or clears the signed-in user's email. Empty submit clears
  # the value (email is optional). Only reachable server-side when
  # `current_user` is set — an anonymous socket sending the event is
  # a silent no-op, same shape as `set_password`.
  @impl true
  def handle_event("save_email", params, socket) do
    case socket.assigns.current_user do
      %User{} = user ->
        new_email = Map.get(params, "email", "")

        case Accounts.update_email(user, new_email) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:current_user, updated)
             |> assign(:email_error, nil)
             |> put_flash(:info, email_saved_flash(updated))}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :email_error, first_email_error(changeset))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("set_password", params, socket) do
    case socket.assigns.current_user do
      %User{} = user ->
        current_password = Map.get(params, "current_password", "")
        new_password = Map.get(params, "password", "")

        case Accounts.update_password(user, current_password, new_password) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:current_user, updated)
             |> assign(:password_error, nil)
             |> put_flash(:info, "Senha atualizada.")}

          {:error, :invalid_current_password} ->
            {:noreply, assign(socket, :password_error, "Senha atual não confere.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :password_error, first_password_error(changeset))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp email_saved_flash(%User{email: nil}), do: "Email removido."
  defp email_saved_flash(%User{}), do: "Email atualizado."

  defp first_email_error(%Ecto.Changeset{errors: errors}) do
    case Enum.find(errors, fn {field, _} -> field == :email end) do
      {:email, {"should be at most " <> _, _}} ->
        "Email muito longo (máximo 200 caracteres)."

      {:email, {msg, _}} ->
        "Email: #{msg}"

      _ ->
        "Não deu pra salvar o email."
    end
  end

  defp first_password_error(%Ecto.Changeset{errors: errors}) do
    case Enum.find(errors, fn {field, _} -> field == :password end) do
      {:password, {"should be at least " <> _, _}} ->
        "Senha muito curta (mínimo 8 caracteres)."

      {:password, {msg, _}} ->
        "Senha: #{msg}"

      _ ->
        "Não deu pra salvar a senha."
    end
  end

  # Empty string (not nil) when the visitor is signed out. That lets the
  # `data-current-user-name` attribute stay a no-op instead of a truthy
  # "None" string that a client-side JSON parse could mishandle.
  defp current_user_display_name(nil), do: ""

  defp current_user_display_name(user),
    do: Rolezinho.Accounts.User.display_name(user)

  # Both `name` and `email` are optional user-provided strings that may
  # arrive as nil, "", or whitespace-only. Treat all three as absent so
  # the account panel doesn't render a blank muted line.
  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_admin?={@current_admin?}
      current_user={@current_user}
      page_title={@page_title}
    >
      <div
        id="settings"
        phx-hook=".Settings"
        data-current-user-name={current_user_display_name(@current_user)}
        data-current-user-id={(@current_user && to_string(@current_user.id)) || ""}
        class="mx-auto max-w-[560px]"
      >
        <header>
          <h1 class="text-2xl font-extrabold tracking-tight">Suas preferências</h1>
          <p class="mt-1 text-[13px] text-muted">
            Ficam salvas só neste aparelho, pra você não digitar tudo de novo no próximo rolê.
          </p>
        </header>

        <!-- ADR-0002: the account section is here rather than a dedicated
             screen because the whole product tries not to grow chrome. When
             signed in, the user sees who they are and can log out; when
             not, they see a quiet pointer to sign in. Everything else on
             this screen is device-local and stays that way. -->
        <section class="mt-6 rounded-card border border-hairline bg-base-100 p-4 shadow-card">
          <h2 class="text-[13px] font-extrabold">Conta</h2>

          <div :if={@current_user} class="mt-3 flex items-center gap-3">
            <img
              :if={@current_user.avatar_url}
              src={@current_user.avatar_url}
              alt={"Avatar de #{Rolezinho.Accounts.User.display_name(@current_user)}"}
              class="size-10 rounded-full ring-1 ring-ink/10"
              referrerpolicy="no-referrer"
            />
            <div class="min-w-0 flex-1">
              <!-- Identifier line: GitHub login for OAuth users (with the
                   @ prefix people recognise), username otherwise. Local-
                   auth accounts have no avatar so the `:if` above just
                   renders the text. -->
              <p :if={@current_user.github_login} class="truncate text-[13px] font-bold">
                @{@current_user.github_login}
              </p>
              <p :if={is_nil(@current_user.github_login)} class="truncate text-[13px] font-bold">
                {@current_user.username}
              </p>
              <!-- Name and email are optional. Show them when present so
                   the user can confirm what's on file; the empty case
                   still gets the introductory copy below. -->
              <p
                :if={present?(@current_user.name)}
                class="truncate text-[11px] text-muted"
              >
                {@current_user.name}
              </p>
              <p
                :if={present?(@current_user.email)}
                class="truncate text-[11px] text-muted"
              >
                {@current_user.email}
              </p>
              <p
                :if={not present?(@current_user.name) and not present?(@current_user.email)}
                class="truncate text-[11px] text-muted"
              >
                Você pode criar rolês e grupos, e gerenciar em qualquer aparelho.
              </p>
            </div>
            <.link
              href={~p"/auth/logout"}
              method="delete"
              class="shrink-0 rounded-row bg-ink/[0.08] px-3 py-2 text-[11px] font-bold text-muted hover:text-ink"
            >
              Sair
            </.link>
          </div>

          <!--
            Password panel. Two flavors:

              * `password_hash` is nil (GitHub-only account) → offer
                to "Definir senha": one field, no current-password
                check. This is the "add a second login path to my
                GitHub account" flow from the 2026-09 amendment.
              * `password_hash` is set → offer to "Alterar senha":
                current + new, both required.

            Server-side (`Accounts.update_password/3`) enforces the
            same rule as the template, so a hostile client that
            fabricates the event without the current-password field
            still gets rejected with `:invalid_current_password`.
          -->
          <div :if={@current_user} class="mt-4 rounded-row border border-hairline bg-base-100 p-3">
            <p class="text-[11px] font-bold text-muted">
              {password_panel_title(@current_user)}
            </p>
            <p class="mt-0.5 text-[11px] leading-snug text-muted">
              {password_panel_hint(@current_user)}
            </p>

            <form phx-submit="set_password" class="mt-3 space-y-2" autocomplete="off">
              <label :if={@current_user.password_hash} class="block">
                <span class="mb-1 block text-[11px] font-bold text-muted">Senha atual</span>
                <input
                  type="password"
                  name="current_password"
                  required
                  autocomplete="current-password"
                  class="w-full rounded-row border border-ink/12 bg-base-100 px-3 py-2 text-[13px] text-ink outline-none focus:border-accent focus:ring-2 focus:ring-accent/20"
                />
              </label>

              <label class="block">
                <span class="mb-1 block text-[11px] font-bold text-muted">Nova senha</span>
                <input
                  type="password"
                  name="password"
                  required
                  minlength="8"
                  autocomplete="new-password"
                  class="w-full rounded-row border border-ink/12 bg-base-100 px-3 py-2 text-[13px] text-ink outline-none focus:border-accent focus:ring-2 focus:ring-accent/20"
                />
              </label>

              <p :if={@password_error} class="text-[11px] font-bold text-error">
                {@password_error}
              </p>

              <button
                type="submit"
                class="w-full rounded-row bg-ink px-3 py-2 text-[11px] font-bold text-ink-content"
              >
                {password_panel_submit(@current_user)}
              </button>
            </form>
          </div>

          <!--
            Email panel. Optional field — the only ambient reason
            it exists is the password-reset flow (2026-09 amendment),
            which needs a mailbox to send the link to. An empty
            submit clears the value, since "I don't want an email on
            file anymore" is a valid state and matches how the
            registration form allows skipping it.
          -->
          <div :if={@current_user} class="mt-4 rounded-row border border-hairline bg-base-100 p-3">
            <p class="text-[11px] font-bold text-muted">Email</p>
            <p class="mt-0.5 text-[11px] leading-snug text-muted">
              Opcional. Guardamos só pra te mandar um link caso precise redefinir a senha — nunca aparece em rolê nenhum.
            </p>

            <form phx-submit="save_email" class="mt-3 space-y-2" autocomplete="on">
              <label class="block">
                <span class="mb-1 block text-[11px] font-bold text-muted">Seu email</span>
                <input
                  type="text"
                  inputmode="email"
                  name="email"
                  value={@current_user.email || ""}
                  maxlength="200"
                  autocomplete="email"
                  placeholder="deixa em branco pra remover"
                  class="w-full rounded-row border border-ink/12 bg-base-100 px-3 py-2 text-[13px] text-ink outline-none focus:border-accent focus:ring-2 focus:ring-accent/20"
                />
              </label>

              <p :if={@email_error} class="text-[11px] font-bold text-error">
                {@email_error}
              </p>

              <button
                type="submit"
                class="w-full rounded-row bg-ink px-3 py-2 text-[11px] font-bold text-ink-content"
              >
                Salvar email
              </button>
            </form>
          </div>

          <!--
            Two paths land on the same account (ADR-0002, 2026-09
            amendment): GitHub OAuth or local username + password.
            Both are surfaced here so a signed-out visitor knows the
            options before deciding — the GitHub button used to be the
            only entry point and it still is for existing users, but a
            new visitor without a GitHub account should not have to
            guess that they can also register with a username.
          -->
          <div :if={is_nil(@current_user)} class="mt-3 space-y-3">
            <p class="text-[11px] leading-relaxed text-muted">
              Você não precisa de conta pra entrar em listas ou ver rolês. Só
              precisa pra criar. Dá pra usar GitHub ou usuário + senha, o que
              preferir.
            </p>

            <div class="flex flex-wrap gap-2">
              <.link
                navigate={~p"/entrar"}
                class="inline-flex items-center gap-2 rounded-row bg-ink px-3 py-2 text-[11px] font-bold text-ink-content"
              >
                <.icon name="tabler-brand-github" class="size-4" /> Entrar com GitHub
              </.link>

              <.link
                navigate={~p"/entrar?tab=entrar"}
                class="inline-flex items-center gap-2 rounded-row border border-ink/15 px-3 py-2 text-[11px] font-bold text-ink"
              >
                <.icon name="tabler-user" class="size-4" /> Entrar com usuário
              </.link>

              <.link
                navigate={~p"/entrar?tab=registrar"}
                class="inline-flex items-center gap-2 rounded-row border border-ink/15 px-3 py-2 text-[11px] font-bold text-ink"
              >
                <.icon name="tabler-user-plus" class="size-4" /> Criar conta
              </.link>
            </div>
          </div>
        </section>

        <section class="mt-6 rounded-card border border-hairline bg-base-100 p-4 shadow-card">
          <h2 class="text-[13px] font-extrabold">Seus dados</h2>
          <p class="mt-0.5 text-[11px] text-muted">
            Usados pra preencher o formulário quando você entra numa lista.
          </p>

          <div class="mt-3.5 space-y-3">
            <label class="block">
              <span class="mb-1 block text-[11px] font-bold text-muted">Nome</span>
              <input
                type="text"
                data-field="name"
                maxlength="60"
                autocomplete="name"
                placeholder="Como te chamam no grupo"
                class="w-full rounded-row border border-ink/12 bg-base-100 px-3.5 py-3 text-[13px] font-semibold text-ink outline-none placeholder:font-normal placeholder:text-ink/35 focus:border-accent focus:ring-2 focus:ring-accent/20"
              />
            </label>

            <label class="block">
              <span class="mb-1 block text-[11px] font-bold text-muted">WhatsApp</span>
              <input
                type="tel"
                data-field="phone"
                maxlength="20"
                autocomplete="tel"
                inputmode="tel"
                placeholder="(91) 98493-3238"
                class="w-full rounded-row border border-ink/12 bg-base-100 px-3.5 py-3 text-[13px] font-semibold text-ink outline-none placeholder:font-normal placeholder:text-ink/35 focus:border-accent focus:ring-2 focus:ring-accent/20"
              />
            </label>
          </div>

          <p class="mt-3 text-[11px] leading-relaxed text-muted">
            Nada disso vai pro servidor agora. Só viaja junto quando você entrar numa lista.
          </p>
        </section>

        <section class="mt-3 rounded-card border border-hairline bg-base-100 p-4 shadow-card">
          <h2 class="text-[13px] font-extrabold">Aparência</h2>
          <p class="mt-0.5 text-[11px] text-muted">
            No automático, segue o tema do seu celular.
          </p>

          <div class="mt-3.5 flex gap-1.5" role="radiogroup" aria-label="Tema">
            <button
              :for={
                {value, label} <- [{"system", "Automático"}, {"light", "Claro"}, {"dark", "Escuro"}]
              }
              type="button"
              role="radio"
              data-theme-option={value}
              aria-checked="false"
              phx-click={JS.dispatch("phx:set-theme")}
              data-phx-theme={value}
              class="flex-1 rounded-row bg-ink/[0.08] py-2.5 text-xs font-bold text-muted aria-checked:bg-ink aria-checked:text-ink-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
            >
              {label}
            </button>
          </div>
        </section>

        <p class="mt-4 text-center text-[11px] text-muted">
          Limpar os dados do navegador apaga tudo isso — e também faz você perder o
          controle das listas em que já entrou.
        </p>

        <!-- API keys shortcut: visible only to signed-in users; the
             dedicated screen handles its own anonymous bounce. -->
        <section
          :if={@current_user}
          class="mt-6 rounded-card border border-hairline bg-base-100 p-4 shadow-card"
        >
          <h2 class="text-[13px] font-extrabold">API</h2>
          <p class="mt-0.5 text-[11px] leading-snug text-muted">
            Chaves de API pra integrações: bots do WhatsApp, dashboards, scripts.
            Cada chave tem permissões próprias.
          </p>
          <.link
            navigate={~p"/me/chaves"}
            class="mt-3 inline-flex items-center gap-1.5 rounded-row border border-ink/15 px-3 py-2 text-[11px] font-bold text-ink"
          >
            <.icon name="tabler-key" class="size-4" /> Minhas chaves
          </.link>
        </section>

        <div class="mt-5 border-t border-hairline pt-4 text-center">
          <.link
            :if={!@current_admin?}
            href={~p"/admin/login"}
            class="text-[11px] font-bold text-muted hover:text-ink"
          >
            Entrar como admin
          </.link>
          <div :if={@current_admin?} class="flex items-center justify-center gap-4">
            <.link navigate={~p"/admin"} class="text-[11px] font-bold text-muted hover:text-ink">
              Painel do admin
            </.link>
            <.link
              href={~p"/admin/logout"}
              method="delete"
              class="text-[11px] font-bold text-muted hover:text-ink"
            >
              Sair
            </.link>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Settings">
        const KEY = "rolezinho:profile"

        const read = () => {
          // localStorage throws in Safari private mode. Preferences are a
          // convenience, so failing to read them just means empty fields.
          try { return JSON.parse(localStorage.getItem(KEY) || "{}") } catch (_) { return {} }
        }

        const write = (profile) => {
          try { localStorage.setItem(KEY, JSON.stringify(profile)) } catch (_) {}
        }

        export default {
          mounted() {
            const profile = read()

            // ADR-0002: seed the name field from the signed-in identity if
            // the device profile has no name yet OR was seeded from a
            // different user id (account switch on the same browser). We
            // record `seededFromUserId` alongside the name so that a
            // subsequent edit by the same user stays sticky, but a new
            // account brings its own name into the field. Users always
            // keep the last-word here — the input listener below stamps
            // the current user id whenever they type, so their
            // intentional choice is respected on the next mount.
            const fromName = this.el.dataset.currentUserName || ""
            const fromUserId = this.el.dataset.currentUserId || ""
            const stale = fromUserId && profile.seededFromUserId !== fromUserId
            if (fromName && (!profile.name || stale)) {
              profile.name = fromName
              profile.seededFromUserId = fromUserId
              write(profile)
            }

            this.el.querySelectorAll("[data-field]").forEach((input) => {
              input.value = profile[input.dataset.field] || ""
              // Saved as you type: there is no submit button, because there is
              // nothing to submit to.
              input.addEventListener("input", () => {
                const next = read()
                next[input.dataset.field] = input.value
                // Stamp the current user id when the user edits the name
                // so the join hook doesn't treat it as stale and re-seed
                // on the next visit.
                if (input.dataset.field === "name" && fromUserId) {
                  next.seededFromUserId = fromUserId
                }
                write(next)
              })
            })

            this.syncTheme()
            // The theme lives under its own key, written by the root layout's
            // switcher, so reflect whatever it currently holds.
            window.addEventListener("storage", () => this.syncTheme())
            this.el.querySelectorAll("[data-theme-option]").forEach((button) => {
              button.addEventListener("click", () => requestAnimationFrame(() => this.syncTheme()))
            })
          },

          syncTheme() {
            let current = "system"
            try { current = localStorage.getItem("phx:theme") || "system" } catch (_) {}

            this.el.querySelectorAll("[data-theme-option]").forEach((button) => {
              const on = button.dataset.themeOption === current
              button.setAttribute("aria-checked", String(on))
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  # Copy for the password panel, keyed on whether the user already has
  # a password hash. GitHub-only users see "Definir"; anyone with a
  # password sees "Alterar".
  defp password_panel_title(%User{password_hash: nil}), do: "Definir senha"
  defp password_panel_title(%User{}), do: "Alterar senha"

  defp password_panel_hint(%User{password_hash: nil}) do
    "Ativa o login com usuário e senha pra essa conta — fica em paralelo ao GitHub."
  end

  defp password_panel_hint(%User{}) do
    "Precisa da senha atual pra trocar. Mínimo 8 caracteres na nova."
  end

  defp password_panel_submit(%User{password_hash: nil}), do: "Definir senha"
  defp password_panel_submit(%User{}), do: "Alterar senha"
end
