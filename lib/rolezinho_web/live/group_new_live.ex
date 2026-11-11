defmodule RolezinhoWeb.GroupNewLive do
  @moduledoc """
  Public form to create a new group.

  Two things the copy has to make clear before the visitor submits:

    * The slug never changes after creation. Once `/g/whatever` exists, it is
      `/g/whatever` forever.
    * Without a password, only the platform admin can edit the group. That is
      the deliberate cost of not having accounts here — the password is the
      bearer secret that lets a non-admin manage the group later. If they
      submit without one, a confirmation modal makes them acknowledge it.
  """
  use RolezinhoWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # ADR-0002: creation is gated. Enforcement is mirrored on the controller.
    if is_nil(socket.assigns.current_user) and not socket.assigns.current_admin? do
      {:ok,
       socket
       |> put_flash(:info, "Entra com o GitHub pra criar.")
       |> push_navigate(to: "/entrar?" <> URI.encode_query(return_to: "/g/criar"))}
    else
      {:ok,
       socket
       |> assign(:page_title, "Criar grupo")
       |> assign_form(default_params(), %{})}
    end
  end

  defp default_params do
    %{
      "name" => "",
      "slug" => "",
      "access_code" => "",
      "visibility" => "public"
    }
  end

  defp assign_form(socket, params, errors) do
    socket
    |> assign(:form_params, params)
    |> assign(:form_errors, errors)
    |> assign(:form, to_form(params, as: :group, errors: form_errors(errors)))
  end

  defp form_errors(errors) do
    for {field, [msg | _]} <- errors, do: {field, {msg, []}}
  end

  @impl true
  def handle_event("validate", %{"group" => params}, socket) do
    {:noreply, assign_form(socket, params, %{})}
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
      <:action>
        <button
          type="submit"
          form="new-group-form"
          data-confirm-if-empty="access_code"
          class="w-full rounded-cta bg-ink px-4 py-4 text-[15px] font-bold text-ink-content shadow-cta transition-transform active:scale-[.97] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        >
          Criar grupo
        </button>
      </:action>

      <div>
        <header class="flex items-center gap-2">
          <.link
            navigate={~p"/"}
            class="grid size-11 shrink-0 place-items-center rounded-full bg-ink/[0.06] text-ink"
            aria-label="Voltar"
          >
            <.icon name="tabler-arrow-left" class="size-[18px]" />
          </.link>
          <h1 class="text-2xl font-extrabold tracking-tight">Criar grupo</h1>
        </header>

        <p class="mt-2 text-[13px] leading-relaxed text-muted">
          Um grupo junta vários rolês debaixo do mesmo link, tipo <code class="font-mono">/g/volei-torres</code>.
        </p>

        <.form
          for={@form}
          id="new-group-form"
          action={~p"/g/criar"}
          method="post"
          phx-change="validate"
          class="mt-5"
        >
          <section class="rounded-card border border-hairline bg-base-100 p-4 shadow-card">
            <h2 class="text-[13px] font-extrabold">O grupo</h2>

            <div class="mt-3.5 space-y-3">
              <.input
                field={@form[:name]}
                label="Nome"
                placeholder="ex.: Vôlei das Torres"
                required
              />
              <.input field={@form[:slug]} label="Link" placeholder="volei-das-torres" required />
              <p class="-mt-2 text-[11px] text-muted">
                Vira <code class="font-mono">/g/{@form[:slug].value || "seu-link"}</code>.
                O link não pode ser trocado depois.
              </p>
            </div>
          </section>

          <section class="mt-3 rounded-card border border-hairline bg-base-100 p-4 shadow-card">
            <h2 class="text-[13px] font-extrabold">Visibilidade</h2>
            <p class="mt-0.5 text-[11px] text-muted">
              Público aparece na home. Oculto só abre por link direto.
            </p>

            <div class="mt-3.5 flex gap-1.5" role="radiogroup" aria-label="Visibilidade">
              <label class={[
                "flex-1 cursor-pointer rounded-row px-3.5 py-2.5 text-center text-xs font-bold",
                (@form[:visibility].value in ["public", :public, nil] && "bg-ink text-ink-content") ||
                  "bg-ink/[0.08] text-muted"
              ]}>
                <input
                  type="radio"
                  name="group[visibility]"
                  value="public"
                  checked={@form[:visibility].value in ["public", :public, nil]}
                  class="sr-only"
                /> Público
              </label>
              <label class={[
                "flex-1 cursor-pointer rounded-row px-3.5 py-2.5 text-center text-xs font-bold",
                (@form[:visibility].value in ["hidden", :hidden] && "bg-ink text-ink-content") ||
                  "bg-ink/[0.08] text-muted"
              ]}>
                <input
                  type="radio"
                  name="group[visibility]"
                  value="hidden"
                  checked={@form[:visibility].value in ["hidden", :hidden]}
                  class="sr-only"
                /> Oculto
              </label>
            </div>
          </section>

          <section class="mt-3 rounded-card border border-hairline bg-base-100 p-4 shadow-card">
            <h2 class="text-[13px] font-extrabold">Senha</h2>
            <p class="mt-0.5 text-[11px] leading-relaxed text-muted">
              A senha é o que te deixa editar o grupo e adicionar rolês depois.
              <strong>Sem senha, só o admin da plataforma consegue editar.</strong>
              Com senha, o link sozinho não abre — a pessoa precisa dela pra ver
              qualquer coisa.
            </p>

            <div class="mt-3.5">
              <.input
                field={@form[:access_code]}
                label="Senha do grupo"
                {RolezinhoWeb.AccessCodeField.ignore_attrs()}
                placeholder="deixa em branco pra grupo aberto"
              />
            </div>
          </section>
        </.form>
      </div>

      <!--
        The confirm dialog is a plain window.confirm rather than a component
        because it is the entire question: creating without a password is a
        one-choice consequence, not a workflow. The hook lives on an invisible
        anchor so the layout slot for the submit button stays clean.
      -->
      <div id="group-new-confirm" phx-hook=".ConfirmIfEmpty" phx-update="ignore"></div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ConfirmIfEmpty">
        export default {
          mounted() {
            const btn = document.querySelector("[data-confirm-if-empty]")
            if (!btn) return
            this.handler = (e) => {
              const form = document.getElementById("new-group-form")
              if (!form) return
              const field = form.elements["group[access_code]"]
              const value = ((field && field.value) || "").trim()
              if (value === "") {
                const ok = window.confirm(
                  "Sem senha, só o admin da plataforma vai poder editar esse grupo depois. Criar assim mesmo?"
                )
                if (!ok) e.preventDefault()
              }
            }
            btn.addEventListener("click", this.handler)
          },
          destroyed() {
            const btn = document.querySelector("[data-confirm-if-empty]")
            if (btn && this.handler) btn.removeEventListener("click", this.handler)
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
