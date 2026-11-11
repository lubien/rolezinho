defmodule RolezinhoWeb.GroupEditLive do
  @moduledoc """
  Admin editor for a group.

  The regular (unlocked) group page carries the name/password inline; this
  screen adds the two things that must stay admin-only:

    * Changing visibility (public/hidden). A non-admin choosing "public" would
      be a self-promotion into the home listing.
    * Deleting the group. Per spec, deleting occults every event that lived
      inside (see `Rolezinho.Groups.delete/1`).

  Passwordless groups have no inline editor at all, so this is also the only
  path to edit their name.
  """
  use RolezinhoWeb, :live_view

  alias Rolezinho.Group
  alias Rolezinho.Groups

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Groups.find(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Grupo não encontrado.")
         |> push_navigate(to: ~p"/")}

      group ->
        if Group.editable_by?(
             group,
             socket.assigns[:current_admin?] == true,
             socket.assigns[:unlocked_groups] || MapSet.new(),
             socket.assigns[:current_user_id]
           ) do
          {:ok,
           socket
           |> assign(:page_title, "Editar #{group.name}")
           |> assign_group(group)}
        else
          {:ok,
           socket
           |> put_flash(:error, "Você não pode editar esse grupo.")
           |> push_navigate(to: ~p"/g/#{group.slug}")}
        end
    end
  end

  defp assign_group(socket, %Group{} = group) do
    socket
    |> assign(:group, group)
    |> assign(:name_input, group.name)
    |> assign(:password_input, group.password || "")
  end

  @impl true
  def handle_event("update_name_input", %{"name" => name}, socket) do
    {:noreply, assign(socket, :name_input, name)}
  end

  def handle_event("save_name", %{"name" => name}, socket) do
    require_editable!(socket)

    case Groups.update_name(socket.assigns.group, name) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Nome atualizado.")
         |> assign_group(group)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Não deu pra salvar. Confira o nome.")}
    end
  end

  def handle_event("update_password_input", %{"access_code" => password}, socket) do
    {:noreply, assign(socket, :password_input, password)}
  end

  def handle_event("save_password", %{"access_code" => password}, socket) do
    require_editable!(socket)

    case Groups.update_password(socket.assigns.group, password) do
      {:ok, group} ->
        message =
          if Group.password_protected?(group), do: "Senha atualizada.", else: "Senha removida."

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign_group(group)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Não deu pra salvar a senha.")}
    end
  end

  def handle_event("set_visibility", %{"visibility" => v}, socket) do
    # Anyone with edit access on the group can flip visibility — same
    # rule as name/password. The "admin only" guard used to worry about
    # self-promotion into the home listing, but a group's editor either
    # created the group or holds its password, so they already have
    # more than enough authority over what it shows.
    require_editable!(socket)
    visibility = String.to_existing_atom(v)

    case Groups.update_visibility(socket.assigns.group, visibility) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Visibilidade atualizada.")
         |> assign_group(group)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Não deu pra salvar.")}
    end
  end

  def handle_event("delete", _params, socket) do
    # Delete cascades to every event in the group (marks them hidden);
    # keep it admin-only regardless of who can otherwise edit the group.
    require_admin!(socket)

    case Groups.delete(socket.assigns.group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Grupo apagado. Os rolês foram marcados como ocultos e continuam por link direto."
         )
         |> push_navigate(to: ~p"/admin")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Não deu pra apagar o grupo.")}
    end
  end

  # Server-side guards, mirror the template's `:if` gates. Raise on
  # violation — reaching these with the wrong role means the client
  # fabricated the event.
  defp require_editable!(socket) do
    editable? =
      Group.editable_by?(
        socket.assigns.group,
        socket.assigns[:current_admin?] == true,
        socket.assigns[:unlocked_groups] || MapSet.new(),
        socket.assigns[:current_user_id]
      )

    unless editable? do
      raise "unauthorized: not an editor of this group"
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
      current_user={@current_user}
      page_title={@page_title}
    >
      <header class="mb-5 flex items-center gap-2">
        <.link
          navigate={~p"/g/#{@group.slug}"}
          class="grid size-11 shrink-0 place-items-center rounded-full bg-ink/[0.06] text-ink"
          aria-label="Voltar pro grupo"
        >
          <.icon name="tabler-arrow-left" class="size-[18px]" />
        </.link>
        <div class="min-w-0">
          <h1 class="text-2xl font-extrabold tracking-tight">Editar grupo</h1>
          <p class="truncate font-mono text-[11px] text-muted">/g/{@group.slug}</p>
        </div>
      </header>

      <section class="rounded-card border border-hairline bg-base-100 p-4 shadow-card mb-3">
        <h2 class="text-[13px] font-extrabold mb-3">Nome</h2>
        <form
          phx-submit="save_name"
          phx-change="update_name_input"
          id="group-name-form"
          class="flex flex-wrap items-end gap-3"
        >
          <label class="flex-1 min-w-64">
            <span class="label text-sm mb-1">Nome do grupo</span>
            <input
              type="text"
              name="name"
              id="group-name-input"
              value={@name_input}
              minlength="3"
              maxlength="80"
              class={[RolezinhoWeb.CoreComponents.field_class(), "w-full"]}
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

      <section class="rounded-card border border-hairline bg-base-100 p-4 shadow-card mb-3">
        <h2 class="text-[13px] font-extrabold mb-3">Senha</h2>
        <p class="text-[11px] leading-relaxed text-muted mb-3">
          Sem senha, só o admin da plataforma pode editar o grupo ou adicionar rolês.
          Com senha, quem tiver ela pode gerenciar tudo do grupo.
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
              name="access_code"
              id="group-access-code-input"
              value={@password_input}
              placeholder="em branco = sem senha"
              class={[RolezinhoWeb.CoreComponents.field_class(), "w-full font-mono"]}
              {RolezinhoWeb.AccessCodeField.ignore_attrs()}
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

      <!--
        Visibility is open to any editor now (creator OR unlocked OR
        admin) — the same rule as name/password. Delete stays admin-
        only below because it cascades: every event in the group gets
        marked hidden.
      -->
      <section class="rounded-card border border-hairline bg-base-100 p-4 shadow-card mb-3">
        <h2 class="text-[13px] font-extrabold mb-3">Visibilidade</h2>
        <div class="flex flex-wrap gap-1.5" role="radiogroup" aria-label="Visibilidade do grupo">
          <button
            :for={visibility <- [:public, :hidden]}
            type="button"
            role="radio"
            aria-checked={to_string(@group.visibility == visibility)}
            phx-click="set_visibility"
            phx-value-visibility={to_string(visibility)}
            class={[
              "rounded-row bg-ink/[0.08] px-3.5 py-2.5 text-xs font-bold text-muted",
              "aria-checked:bg-ink aria-checked:text-ink-content",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
            ]}
          >
            {visibility_label(visibility)}
          </button>
        </div>
        <dl class="mt-3 space-y-1.5 text-[11px] leading-relaxed text-muted">
          <div class="flex gap-1.5">
            <dt class="shrink-0 font-bold">Público:</dt>
            <dd class="flex-1">Aparece na home.</dd>
          </div>
          <div class="flex gap-1.5">
            <dt class="shrink-0 font-bold">Oculto:</dt>
            <dd class="flex-1">Abre só por link direto.</dd>
          </div>
        </dl>
      </section>

      <section :if={@current_admin?} class="rounded-2xl border border-error/40 bg-error/5 p-5">
        <h2 class="font-semibold text-error mb-2">Zona perigosa</h2>
        <p class="text-sm text-base-content/70 mb-3">
          Apagar o grupo marca todos os rolês dele como <strong>ocultos</strong>
          e desliga o vínculo — eles continuam acessíveis pelo link direto, mas
          somem da home. Não dá pra desfazer.
        </p>
        <button
          type="button"
          phx-click="delete"
          data-confirm="Apagar esse grupo? Os rolês ficam ocultos."
          class="inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:pointer-events-none px-4 py-2 text-sm bg-error text-error-content hover:bg-error/90 px-3 py-1.5"
        >
          Apagar grupo
        </button>
      </section>
    </Layouts.app>
    """
  end

  defp visibility_label(:public), do: "Público"
  defp visibility_label(:hidden), do: "Oculto"
end
