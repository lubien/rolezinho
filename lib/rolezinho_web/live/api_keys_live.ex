defmodule RolezinhoWeb.ApiKeysLive do
  @moduledoc """
  Dedicated screen at `/me/chaves` for managing REST API keys.

  Two live_actions:

    * `:index` — the key list (active + revoked), with a *Criar
      chave* link and a *Revogar* button per row.
    * `:new` — the create form (name + 2×3 permission matrix),
      which after a successful submit swaps the same screen's body
      for a one-time raw-token display. The raw token lives *only*
      in socket assigns (never in the URL, never persisted); a
      refresh wipes it out, matching the backend contract: lose
      it, revoke and recreate.

  Anonymous visitors are bounced to `/entrar?return_to=...`. Keys
  belong to the signed-in user; a URL for someone else's key id
  just 404s via `Accounts.get_api_key_for/2`.
  """
  use RolezinhoWeb, :live_view

  alias Rolezinho.Accounts
  alias Rolezinho.Accounts.ApiKey

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_user do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/entrar?return_to=/me/chaves")}

      user ->
        {:ok,
         socket
         |> assign(:page_title, "Chaves de API")
         |> assign(:keys, Accounts.list_api_keys_for(user))
         |> assign(:form_name, "")
         |> assign(:form_permissions, MapSet.new())
         |> assign(:form_error, nil)
         |> assign(:revealed_token, nil)
         |> assign(:reveal_key, nil)}
    end
  end

  @impl true
  def handle_event("update_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :form_name, name)}
  end

  def handle_event("toggle_permission", %{"scope" => scope}, socket) do
    perms = socket.assigns.form_permissions

    perms =
      if MapSet.member?(perms, scope),
        do: MapSet.delete(perms, scope),
        else: MapSet.put(perms, scope)

    {:noreply, assign(socket, :form_permissions, perms)}
  end

  def handle_event("create", params, socket) do
    # Prefer the submitted form params for the name (works even if
    # the user never typed into the live `phx-change` channel, e.g.
    # under `render_submit/2` in tests). Fall back to the socket's
    # mirrored `form_name` for `phx-change` driven renders.
    name =
      Map.get(params, "name") || socket.assigns.form_name || ""

    attrs = %{
      "name" => name,
      "permissions" => MapSet.to_list(socket.assigns.form_permissions)
    }

    case Accounts.create_api_key(socket.assigns.current_user, attrs) do
      {:ok, key, raw_token} ->
        # Stash the raw token + the key metadata in socket assigns
        # and swap the render to the reveal panel. We stay on
        # `/me/chaves/nova` because the reveal is a transient state;
        # if the user reloads, they end up back on the empty form,
        # which is the honest story (the token is unrecoverable).
        {:noreply,
         socket
         |> assign(:revealed_token, raw_token)
         |> assign(:reveal_key, key)
         |> assign(:keys, Accounts.list_api_keys_for(socket.assigns.current_user))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form_error, first_error(changeset))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    key_id = String.to_integer(id)

    case Accounts.revoke_api_key(socket.assigns.current_user, key_id) do
      {:ok, _key} ->
        {:noreply,
         socket
         |> put_flash(:info, "Chave revogada.")
         |> assign(:keys, Accounts.list_api_keys_for(socket.assigns.current_user))}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Chave não encontrada.")}
    end
  end

  defp first_error(%Ecto.Changeset{errors: [{field, {msg, _}} | _]}) do
    "#{field}: #{msg}"
  end

  defp first_error(_), do: "Não deu pra criar a chave."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_admin?={@current_admin?}
      current_user={@current_user}
      page_title={@page_title}
    >
      <div class="mx-auto max-w-[640px] px-2 py-6">
        <header class="mb-6">
          <div class="flex items-center gap-2 text-[11px] font-bold text-muted">
            <.link navigate={~p"/me"} class="underline">Preferências</.link>
            <span>/</span>
            <span>Chaves de API</span>
          </div>
          <h1 class="mt-2 text-2xl font-extrabold tracking-tight">Chaves de API</h1>
          <p class="mt-1 text-[13px] leading-relaxed text-muted">
            Chaves te deixam acessar a API REST. Cada chave tem permissões próprias
            e um limite de requisições por minuto. Doc da API: <code>/api.md</code>.
          </p>
        </header>

        <.list_view :if={@live_action == :index} keys={@keys} />

        <!-- `:new` is a two-phase screen: the form by default; the
             reveal panel after a successful create. The split lives
             on `@revealed_token`, which is nil until the create
             handler stashes the raw string. -->
        <.new_view
          :if={@live_action == :new and is_nil(@revealed_token)}
          form_name={@form_name}
          form_permissions={@form_permissions}
          form_error={@form_error}
        />
        <.reveal_view
          :if={@live_action == :new and not is_nil(@revealed_token)}
          key={@reveal_key}
          token={@revealed_token}
        />
      </div>
    </Layouts.app>
    """
  end

  # ---------- Index ----------

  attr :keys, :list, required: true

  defp list_view(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <p class="text-[11px] text-muted">
        {length(@keys)} chave(s), {active_count(@keys)} ativa(s).
      </p>
      <.link
        navigate={~p"/me/chaves/nova"}
        class="inline-flex items-center gap-1.5 rounded-cta bg-ink px-3 py-2 text-[12px] font-bold text-ink-content shadow-cta"
      >
        <.icon name="tabler-plus" class="size-4" /> Nova chave
      </.link>
    </div>

    <ul :if={@keys != []} class="mt-4 space-y-2">
      <li
        :for={key <- @keys}
        class={[
          "rounded-card border p-3",
          key.revoked_at && "border-hairline bg-base-100 opacity-60",
          !key.revoked_at && "border-hairline bg-base-100"
        ]}
      >
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0 flex-1">
            <p class="truncate text-[13px] font-bold text-ink">
              {key.name}
              <span
                :if={key.revoked_at}
                class="ml-1.5 rounded-full bg-ink/[0.08] px-1.5 py-[1px] text-[10px] font-bold uppercase tracking-wide text-muted"
              >
                revogada
              </span>
            </p>
            <p class="mt-0.5 font-mono text-[11px] text-muted">{key.key_prefix}…</p>
            <p class="mt-1 text-[11px] text-muted">
              {permissions_summary(key.permissions)}
            </p>
            <p class="mt-1 text-[10px] text-muted">
              Criada {format_date(key.inserted_at)}
              {if key.last_used_at,
                do: "· Último uso #{format_date(key.last_used_at)}",
                else: "· Nunca usada"}
            </p>
          </div>
          <button
            :if={!key.revoked_at}
            type="button"
            phx-click="revoke"
            phx-value-id={key.id}
            data-confirm={"Revogar a chave \"#{key.name}\"? Essa ação não pode ser desfeita."}
            class="shrink-0 rounded-row border border-error/30 bg-error/5 px-2 py-1 text-[11px] font-bold text-error hover:bg-error/10"
          >
            Revogar
          </button>
        </div>
      </li>
    </ul>

    <div
      :if={@keys == []}
      class="mt-4 rounded-card border border-hairline bg-base-100 p-6 text-center"
    >
      <p class="text-[13px] font-semibold text-ink">Nenhuma chave ainda.</p>
      <p class="mt-1 text-[11px] text-muted">
        Cria a primeira pra usar a API.
      </p>
    </div>
    """
  end

  defp active_count(keys), do: Enum.count(keys, &is_nil(&1.revoked_at))

  defp format_date(%DateTime{} = dt) do
    dt |> DateTime.to_date() |> Date.to_string()
  end

  defp format_date(_), do: ""

  defp permissions_summary([]), do: "Sem permissões (chave inutilizável)."

  defp permissions_summary(perms) do
    Enum.map_join(perms, ", ", &humanize_scope/1)
  end

  defp humanize_scope("events:read"), do: "Rolês (leitura)"
  defp humanize_scope("events:write"), do: "Rolês (escrita)"
  defp humanize_scope("groups:read"), do: "Grupos (leitura)"
  defp humanize_scope("groups:write"), do: "Grupos (escrita)"
  defp humanize_scope("participants:read"), do: "Participantes (leitura)"
  defp humanize_scope("participants:write"), do: "Participantes (escrita)"
  defp humanize_scope(other), do: other

  # ---------- New ----------

  attr :form_name, :string, required: true
  attr :form_permissions, MapSet, required: true
  attr :form_error, :string, required: true

  defp new_view(assigns) do
    ~H"""
    <form phx-submit="create" phx-change="update_name" class="space-y-4" autocomplete="off">
      <div class="rounded-card border border-hairline bg-base-100 p-4">
        <label class="block">
          <span class="mb-1 block text-[11px] font-bold text-muted">Nome</span>
          <input
            type="text"
            name="name"
            value={@form_name}
            required
            maxlength="100"
            placeholder="Ex: bot-whatsapp, dashboard-leitura"
            class="w-full rounded-row border border-ink/12 bg-base-100 px-3 py-2 text-[13px] font-semibold text-ink outline-none focus:border-accent focus:ring-2 focus:ring-accent/20"
          />
          <p class="mt-1 text-[10px] text-muted">
            Só pra você identificar essa chave depois.
          </p>
        </label>
      </div>

      <div class="rounded-card border border-hairline bg-base-100 p-4">
        <p class="text-[11px] font-bold text-muted">Permissões</p>
        <p class="mt-0.5 text-[10px] text-muted">
          Leitura: listar e buscar. Escrita: criar, editar, remover. A chave só
          mexe em rolês e grupos que você mesmo criou.
        </p>

        <div class="mt-3 grid grid-cols-[1fr_auto_auto] gap-x-4 gap-y-2 text-[12px]">
          <div></div>
          <div class="text-center text-[10px] font-bold uppercase text-muted">Leitura</div>
          <div class="text-center text-[10px] font-bold uppercase text-muted">Escrita</div>

          <.scope_row
            label="Rolês"
            read_scope="events:read"
            write_scope="events:write"
            permissions={@form_permissions}
          />
          <.scope_row
            label="Grupos"
            read_scope="groups:read"
            write_scope="groups:write"
            permissions={@form_permissions}
          />
          <.scope_row
            label="Participantes"
            read_scope="participants:read"
            write_scope="participants:write"
            permissions={@form_permissions}
          />
        </div>
      </div>

      <p :if={@form_error} class="text-[12px] font-bold text-error">{@form_error}</p>

      <div class="flex items-center justify-between gap-3">
        <.link navigate={~p"/me/chaves"} class="text-[12px] font-bold text-muted underline">
          Cancelar
        </.link>
        <button
          type="submit"
          class="inline-flex items-center gap-1.5 rounded-cta bg-ink px-4 py-2.5 text-[13px] font-bold text-ink-content shadow-cta"
        >
          <.icon name="tabler-check" class="size-4" /> Criar chave
        </button>
      </div>
    </form>
    """
  end

  attr :label, :string, required: true
  attr :read_scope, :string, required: true
  attr :write_scope, :string, required: true
  attr :permissions, MapSet, required: true

  defp scope_row(assigns) do
    ~H"""
    <span class="self-center font-bold text-ink">{@label}</span>
    <label class="justify-self-center">
      <input
        type="checkbox"
        phx-click="toggle_permission"
        phx-value-scope={@read_scope}
        checked={MapSet.member?(@permissions, @read_scope)}
        class="size-4 rounded border-ink/30 text-accent focus:ring-accent"
      />
    </label>
    <label class="justify-self-center">
      <input
        type="checkbox"
        phx-click="toggle_permission"
        phx-value-scope={@write_scope}
        checked={MapSet.member?(@permissions, @write_scope)}
        class="size-4 rounded border-ink/30 text-accent focus:ring-accent"
      />
    </label>
    """
  end

  # ---------- Reveal ----------

  attr :key, ApiKey, required: true
  attr :token, :string, required: true

  defp reveal_view(assigns) do
    ~H"""
    <div class="rounded-card border border-warning/40 bg-warning/10 p-4">
      <div class="flex items-start gap-2">
        <.icon name="tabler-alert-triangle" class="size-5 shrink-0 text-warning" />
        <div>
          <p class="text-[13px] font-bold text-ink">
            Copie essa chave agora. Ela não vai aparecer de novo.
          </p>
          <p class="mt-1 text-[11px] text-muted">
            Guardamos só o hash. Se perder, revoga e cria outra.
          </p>
        </div>
      </div>
    </div>

    <div class="mt-3 rounded-card border border-hairline bg-base-100 p-4">
      <p class="text-[11px] font-bold text-muted">Chave de "{@key.name}"</p>
      <div
        id="api-key-reveal"
        phx-hook=".CopyKey"
        data-token={@token}
        class="mt-2 flex items-center gap-2"
      >
        <code
          id="api-key-value"
          phx-no-curly-interpolation
          class="min-w-0 flex-1 overflow-x-auto rounded-row border border-ink/12 bg-ink/[0.04] px-3 py-2 font-mono text-[12px] text-ink"
        >{@token}</code>
        <button
          type="button"
          data-copy-trigger
          class="shrink-0 rounded-row bg-ink px-3 py-2 text-[12px] font-bold text-ink-content"
        >
          Copiar
        </button>
      </div>
    </div>

    <div class="mt-6 flex items-center justify-between gap-3">
      <.link navigate={~p"/me/chaves"} class="text-[12px] font-bold text-muted underline">
        Voltar para a lista
      </.link>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyKey">
      export default {
        mounted() {
          const token = this.el.dataset.token
          const trigger = this.el.querySelector("[data-copy-trigger]")
          if (!token || !trigger) return

          trigger.addEventListener("click", async () => {
            try {
              await navigator.clipboard.writeText(token)
              const originalText = trigger.textContent
              trigger.textContent = "Copiada!"
              setTimeout(() => (trigger.textContent = originalText), 1500)
            } catch (err) {
              // Clipboard permission denied / insecure context — fall
              // back to selecting the token so the user can copy
              // manually.
              const code = this.el.querySelector("#api-key-value")
              const range = document.createRange()
              range.selectNodeContents(code)
              const selection = window.getSelection()
              selection.removeAllRanges()
              selection.addRange(range)
            }
          })
        }
      }
    </script>
    """
  end
end
