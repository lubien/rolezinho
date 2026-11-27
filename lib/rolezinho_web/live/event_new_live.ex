defmodule RolezinhoWeb.EventNewLive do
  @moduledoc "Admin form to create a new rolezinho."
  use RolezinhoWeb, :live_view

  # Category suggestions shown as autocomplete hints (HTML `<datalist>`). The
  # field stays a plain text input — these are suggestions, not a restricted
  # list, so someone can still write "Coworking" or "Aniversário" or anything
  # else. The four defaults cover the informal categories the group text
  # research surfaced most often.
  @category_suggestions ~w(Trabalho Networking Esportes Social)

  @impl true
  def mount(params, _session, socket) do
    group_slug = params |> Map.get("group", "") |> to_string() |> String.trim()

    # ADR-0002: creation is the one gated surface. Anon visitors get sent to
    # the sign-in prompt; the admin bypass still works. Enforcement also
    # lives on the controller (POST /criar) as defense in depth.
    if is_nil(socket.assigns.current_user) and not socket.assigns.current_admin? do
      return_to = build_return_to(group_slug)

      {:ok,
       socket
       |> put_flash(:info, "Entra com o GitHub pra criar.")
       |> push_navigate(to: "/entrar?" <> URI.encode_query(return_to: return_to))}
    else
      group = if group_slug != "", do: Rolezinho.Groups.find(group_slug), else: nil

      {:ok,
       socket
       |> assign(:page_title, "Criar rolezinho")
       |> assign(:group, group)
       |> assign(:group_slug, if(group, do: group.slug, else: ""))
       # `slug_touched?` starts false so the "auto-slugify from title" helper
       # is free to fill in the slug on the first title keystroke. Once the
       # user has typed into the slug field themselves, this flips to true and
       # the field belongs to them from then on.
       |> assign(:slug_touched?, false)
       # The payment card starts closed: most rolês are free or settled
       # outside the app, so the form only asks for money when asked to.
       |> assign(:payment_open?, false)
       |> assign(:category_suggestions, @category_suggestions)
       |> assign_form(default_params(group_slug), %{})}
    end
  end

  defp build_return_to(""), do: "/criar"
  defp build_return_to(group_slug), do: "/criar?group=" <> URI.encode_www_form(group_slug)

  defp default_params(group_slug) do
    %{
      "title" => "",
      "slug" => "",
      "local" => "",
      "category" => "",
      "date" => "",
      "time" => "",
      "description" => "",
      "main_size" => "18",
      "wait_size" => "3",
      "auto_promote" => "false",
      "access_code" => "",
      # Not-hidden by default for a signed-in creator (they can see their
      # own hidden rolezinhos on the home too now, but the safest default
      # is still "visible"). The context has its own anonymous-safety
      # override for callers without a user id.
      "hidden" => "false",
      "group" => group_slug
    }
    |> Map.merge(payment_defaults())
  end

  # The fields owned by the payment card. Closing the card puts these back,
  # so "no payment" really submits no price and no Pix key.
  defp payment_defaults do
    %{
      "split_method" => "per_person",
      "price" => "",
      "total" => "",
      "pix_key_type" => "",
      "pix_key" => ""
    }
  end

  defp assign_form(socket, params, errors) do
    socket
    |> assign(:form_params, params)
    |> assign(:form_errors, errors)
    |> assign(:form, to_form(params, as: :event, errors: form_errors(errors)))
  end

  defp form_errors(errors) do
    for {field, [msg | _]} <- errors, do: {field, {msg, []}}
  end

  @impl true
  def handle_event("validate", %{"event" => params} = payload, socket) do
    target = Map.get(payload, "_target", [])

    # Two threads to keep in sync here:
    #   * `slug_touched?` — once the user has typed anything into the slug
    #     field themselves, we stop derivating from title/date. The check on
    #     `_target` is the signal.
    #   * `maybe_autofill_slug/2` — only runs while the field is still
    #     considered untouched *and* the user is editing some other field.
    slug_touched? = socket.assigns.slug_touched? or target == ["event", "slug"]

    params =
      if slug_touched? do
        params
      else
        autofill_slug(params)
      end

    {:noreply,
     socket
     |> assign(:slug_touched?, slug_touched?)
     |> assign_form(params, %{})}
  end

  def handle_event("open_payment", _params, socket) do
    {:noreply,
     socket
     |> assign(:payment_open?, true)
     |> assign_form(Map.merge(socket.assigns.form_params, payment_defaults()), %{})}
  end

  def handle_event("close_payment", _params, socket) do
    {:noreply,
     socket
     |> assign(:payment_open?, false)
     |> assign_form(Map.merge(socket.assigns.form_params, payment_defaults()), %{})}
  end

  # Derives the slug from the current title (plus `-dd-mm` when a date is
  # set) and stuffs it back into the form params. Leaves the slug empty when
  # the title is empty — a bare `-15-08` would be a slug about nothing.
  defp autofill_slug(params) do
    title = params |> Map.get("title", "") |> to_string()
    date = params |> Map.get("date", "") |> to_string()

    generated =
      case slugify(title) do
        "" -> ""
        base -> base <> date_suffix(date)
      end

    Map.put(params, "slug", generated)
  end

  # Portuguese-friendly slugifier: strips accents via NFD normalization, keeps
  # only [a-z0-9], collapses runs to single hyphens, trims leading/trailing
  # hyphens. Length-capped to leave room for the date suffix under the 62-char
  # ceiling in `Rolezinho.Event`'s slug regex.
  defp slugify(title) do
    title
    |> String.trim()
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 50)
    |> String.trim("-")
  end

  # A date like `2026-08-15` renders as `-15-08` — day first, month second, to
  # match how the group actually says it out loud ("dia 15 do 8"). Ignores
  # anything the browser hands us that isn't a valid ISO date.
  defp date_suffix(""), do: ""
  defp date_suffix(nil), do: ""

  defp date_suffix(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> "-" <> pad2(date.day) <> "-" <> pad2(date.month)
      _ -> ""
    end
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

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
          form="new-event-form"
          class="w-full rounded-cta bg-ink px-4 py-4 text-[15px] font-bold text-ink-content shadow-cta transition-transform active:scale-[.97] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        >
          Criar rolezinho
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
          <h1 class="text-2xl font-extrabold tracking-tight">Criar rolezinho</h1>
        </header>

        <.form
          for={@form}
          id="new-event-form"
          action={~p"/criar"}
          method="post"
          phx-change="validate"
          class="mt-5"
        >
          <!--
            The group binding travels as a hidden field so the controller can
            authorize it. It is a name, not an id: a name we validate against
            the caller's session on submit. Ids would let anyone drop into any
            group by number.
          -->
          <input type="hidden" name="event[group]" value={@group_slug} />

          <div
            :if={@group}
            class="mb-3 flex items-center gap-2.5 rounded-card border border-hairline bg-accent/[0.08] p-3.5 text-[12px]"
          >
            <.icon name="tabler-users-group" class="size-4 shrink-0 text-accent" />
            <p class="leading-tight">
              Criando dentro do grupo <strong>{@group.name}</strong>. Esse rolê
              não aparece na home — só na página do grupo.
            </p>
          </div>

          <!--
            The name is the only thing the form asks for. Every other card
            either starts with a working default or is optional, so someone
            can type a name and hit "Criar rolezinho".
          -->
          <section
            id="new-event-basics"
            class="rounded-card border border-hairline bg-base-100 p-4 shadow-card"
          >
            <h2 class="text-[13px] font-extrabold">O rolê</h2>

            <div class="mt-3.5 space-y-3">
              <.input
                field={@form[:title]}
                label="Nome"
                placeholder="ex.: Vôlei ver-o-beach"
                required
              />
              <div>
                <.input
                  field={@form[:description]}
                  type="textarea"
                  label="Recado pro grupo"
                  placeholder="O que levar, onde estacionar, qualquer coisa que ajude."
                  rows="2"
                  data-autogrow
                />
                <!-- The syntax is the group's own, so the hint names it rather than
                     teaching markdown: someone who formats messages already knows
                     this and does not need to be told it is markdown. -->
                <p class="mt-1 text-[11px] text-muted">
                  Dá pra usar <code class="font-mono font-bold">*negrito*</code>,
                  <code class="font-mono italic">_itálico_</code>
                  e <code class="font-mono line-through">~riscado~</code>, como no WhatsApp.
                </p>
              </div>
            </div>
          </section>

          <section
            id="new-event-details"
            class="mt-3 rounded-card border border-hairline bg-base-100 p-4 shadow-card"
          >
            <div class="flex items-baseline justify-between gap-2">
              <h2 class="text-[13px] font-extrabold">Onde e quando</h2>
              <span class="rounded-full bg-tint px-2 py-0.5 text-[11px] font-semibold text-muted">
                Opcional
              </span>
            </div>
            <p class="mt-0.5 text-[11px] text-muted">
              Pode deixar em branco e preencher depois.
            </p>

            <div class="mt-3.5 space-y-3">
              <.input field={@form[:local]} label="Onde" placeholder="ex.: Rua Caripunas" />
              <div class="grid grid-cols-2 gap-2">
                <.input field={@form[:date]} type="date" label="Quando" />
                <.input field={@form[:time]} type="time" label="Que horas" />
              </div>
              <!--
                Category stays a free-form text field — the datalist below is
                only there as a hint on desktop and a suggestion sheet on
                mobile. Any string still goes through, including the ones
                the group actually uses that we did not think of.
              -->
              <.input
                field={@form[:category]}
                label="Categoria"
                placeholder="ex.: Trabalho, Esportes"
                list="event-category-suggestions"
              />
              <datalist id="event-category-suggestions">
                <option :for={suggestion <- @category_suggestions} value={suggestion} />
              </datalist>
            </div>
          </section>

          <.action_button
            :if={not @payment_open?}
            id="new-event-add-payment"
            type="button"
            variant="outline"
            phx-click="open_payment"
            class="mt-3"
          >
            <.icon name="tabler-plus" class="size-[18px]" /> Adicionar pagamento
          </.action_button>

          <!--
            Closing this card means "no payment": `close_payment` resets every
            field in it, and the fields leave the DOM, so the submit carries no
            price and no Pix key.
          -->
          <section
            :if={@payment_open?}
            id="new-event-payment"
            class="mt-3 rounded-card border border-hairline bg-base-100 p-4 shadow-card"
          >
            <div class="flex items-start justify-between gap-2">
              <div>
                <h2 class="text-[13px] font-extrabold">Pagamento</h2>
                <p class="mt-0.5 text-[11px] text-muted">
                  Como dividir a conta e pra onde mandar o Pix.
                </p>
              </div>
              <.icon_button
                id="new-event-remove-payment"
                name="tabler-x"
                label="Remover pagamento"
                phx-click="close_payment"
                class="-mr-2 -mt-2"
              />
            </div>

            <div class="mt-3.5 space-y-3">
              <.split_method_fields form={@form} />
              <!--
                Explicit type: an 11-digit number is ambiguous (phone OR CPF),
                so we ask the organizer which one it is instead of guessing.
                Placed *before* the key input so the choice frames what the
                field expects.
              -->
              <.input
                field={@form[:pix_key_type]}
                type="select"
                label="Tipo da chave"
                prompt="Escolha o tipo"
                options={
                  Enum.map(Rolezinho.Pix.types(), fn t ->
                    {Rolezinho.Pix.type_label(t), Atom.to_string(t)}
                  end)
                }
              />
              <!--
                Password managers keep misidentifying this field as a
                password. It is not a password: it is a public Pix key
                someone pastes so friends can send money.
                `autocomplete="off"` + the three vendor-specific ignore
                data-attrs (1Password / LastPass / Bitwarden) tell every
                mainstream manager to stay out.
              -->
              <.input
                field={@form[:pix_key]}
                label="Chave Pix"
                placeholder="telefone, CPF, e-mail ou aleatória"
                autocomplete="off"
                data-1p-ignore="true"
                data-lpignore="true"
                data-bwignore="true"
                data-form-type="other"
              />
            </div>
          </section>

          <!--
            Advanced is a native <details>: collapsing only hides it, the
            inputs stay in the form and keep their values. `ignore_attributes`
            stops LiveView patches from resetting the open/closed state the
            browser owns. The `.OpenOnInvalid` hook covers the one gap: an
            invalid field inside a collapsed <details> silently blocks the
            submit, so it opens the card and lets the browser point at it.
          -->
          <details
            id="new-event-advanced"
            phx-hook=".OpenOnInvalid"
            phx-mounted={JS.ignore_attributes(["open"])}
            class="group mt-3 rounded-card border border-hairline bg-base-100 shadow-card"
          >
            <summary class="flex min-h-11 cursor-pointer list-none items-center justify-between gap-2 p-4 [&::-webkit-details-marker]:hidden">
              <div>
                <h2 class="text-[13px] font-extrabold">Avançado</h2>
                <p class="mt-0.5 text-[11px] text-muted">
                  Vagas, visibilidade, senha e link. Já vem preenchido.
                </p>
              </div>
              <.icon
                name="tabler-chevron-down"
                class="size-[18px] shrink-0 text-muted transition-transform group-open:rotate-180"
              />
            </summary>

            <div class="divide-y divide-hairline border-t border-hairline px-4">
              <div class="py-4">
                <h3 class="text-[13px] font-bold">Vagas</h3>
                <div class="mt-3 grid grid-cols-2 gap-2">
                  <.input
                    field={@form[:main_size]}
                    type="number"
                    label="Na lista"
                    min="1"
                    max="500"
                  />
                  <.input
                    field={@form[:wait_size]}
                    type="number"
                    label="Na espera"
                    min="0"
                    max="100"
                  />
                </div>
                <p class="mt-2 text-[11px] text-muted">
                  0 na espera desliga a fila. Depois de criada, ela não tem limite.
                </p>
                <div class="mt-3">
                  <.input
                    field={@form[:auto_promote]}
                    type="checkbox"
                    label="Promover automaticamente da reserva"
                  />
                  <p class="-mt-1 text-[11px] text-muted">
                    Quando alguém sair da lista, o próximo da reserva entra sozinho.
                  </p>
                </div>
              </div>

              <div class="py-4">
                <h3 class="text-[13px] font-bold">Visibilidade</h3>
                <p class="mt-0.5 text-[11px] text-muted">
                  Oculto não aparece na home. Só quem tem o link entra.
                </p>
                <label class="mt-3 flex min-h-11 items-center gap-2 text-[13px]">
                  <input
                    type="checkbox"
                    name="event[hidden]"
                    value="true"
                    checked={@form[:hidden].value in [true, "true", "on"]}
                    class="size-4 rounded border-ink/30 text-accent focus:ring-accent"
                  />
                  <span class="font-bold">Oculto</span>
                </label>
              </div>

              <div class="py-4">
                <h3 class="text-[13px] font-bold">Senha</h3>
                <p class="mt-0.5 text-[11px] text-muted">
                  Em branco, qualquer um com o link entra. Com senha, o link sozinho não basta.
                </p>
                <div class="mt-3">
                  <.input
                    field={@form[:access_code]}
                    label="Senha da lista"
                    {RolezinhoWeb.AccessCodeField.ignore_attrs()}
                  />
                </div>
              </div>

              <!--
                The auto-slugify (title + `-dd-mm`) fills this in, so most
                people never open it. It is not `required` in the browser: a
                required field inside a collapsed <details> blocks the submit
                with no visible field to fix. The server still rejects an
                empty slug.
              -->
              <div id="new-event-link" class="py-4">
                <h3 class="text-[13px] font-bold">Link</h3>
                <p class="mt-0.5 text-[11px] leading-relaxed text-muted">
                  A gente já sugere um link a partir do nome e da data — dá pra trocar
                  se você quiser algo diferente.
                </p>
                <div class="mt-3">
                  <.input
                    field={@form[:slug]}
                    label="Endereço do rolê"
                    placeholder="volei-ver-o-beach"
                  />
                  <p class="mt-2 text-[11px] text-muted">
                    Vira <code class="font-mono">/r/{@form[:slug].value || "seu-link"}</code>
                  </p>
                </div>
              </div>
            </div>
          </details>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".OpenOnInvalid">
            export default {
              mounted() {
                this.el.addEventListener("invalid", () => { this.el.open = true }, true)
              }
            }
          </script>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
