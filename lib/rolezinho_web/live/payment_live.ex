defmodule RolezinhoWeb.PaymentLive do
  @moduledoc """
  What to pay and how, right after getting a slot.

  This exists because the payment is the part that quietly does not happen. On
  the list screen the Pix key is one detail among many; here it is the only
  thing, at the moment the person is most likely to act on it.

  The app never confirms anything (RN-10). Marking paid is a declaration by the
  person who says they sent the money (RN-11), which is why the button says
  "Já fiz o Pix" rather than "Pagar" — it records what they did somewhere else.
  """
  use RolezinhoWeb, :live_view

  import Phoenix.HTML, only: [raw: 1]

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.Cash
  alias Rolezinho.Event.Policy
  alias Rolezinho.Events
  alias Rolezinho.Pix
  alias RolezinhoWeb.Plugs.Participant

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Events.find(slug, visibility: :public) do
      %Event{} = event -> {:ok, assign_event(socket, event)}
      nil -> {:ok, socket |> put_flash(:error, "Rolezinho não encontrado.") |> to_home()}
    end
  end

  defp assign_event(socket, %Event{} = event) do
    participant_id = Map.get(socket.assigns[:participants] || %{}, event.slug)
    user_id = socket.assigns[:current_user_id]
    row = own_row(event, participant_id, user_id)

    socket
    |> assign(:page_title, "Pagamento · #{event.title}")
    |> assign(:event, event)
    |> assign(:participant_id, participant_id)
    |> assign(:user_id, user_id)
    |> assign(:row, row)
    |> assign(:amount, Cash.format_amount(Cash.per_person_cents(event)))
    |> assign(:pix, pix_for(event))
  end

  # Only the row this caller owns matters here — the screen is about settling
  # your own share (RN-12). Ownership matches by either identity (ADR-0002):
  # the per-device token, or the signed-in GitHub user.
  defp own_row(%Event{main_list: main, wait_list: wait}, participant_id, user_id) do
    (main ++ wait)
    |> Enum.find(&Attendee.owns?(&1, participant_id, user_id))
  end

  # When the organizer chose an explicit `pix_key_type`, canonicalize under
  # that type — no guessing, so an 11-digit phone stays a phone. Legacy
  # events with a key but no type fall back to `Pix.classify/1`, matching
  # the old behavior until the organizer picks a type on the next edit.
  defp pix_for(%Event{pix_key: key, pix_key_type: type})
       when is_binary(key) and key != "" and is_atom(type) and not is_nil(type) do
    case Pix.canonicalize(key, type) do
      {:ok, canonical} ->
        # `display_as/2` also honors the explicit type — `display/1` would
        # fall back to the guesser and format a bare 11-digit phone as a
        # CPF ("123.456.789-00"), which is the whole bug we set out to
        # kill when we added `pix_key_type`.
        %{key: canonical, display: Pix.display_as(key, type) || key, type: type}

      :error ->
        nil
    end
  end

  defp pix_for(%Event{pix_key: key}) when is_binary(key) and key != "" do
    case Pix.classify(key) do
      {:ok, type, canonical} -> %{key: canonical, display: Pix.display(key) || key, type: type}
      :error -> nil
    end
  end

  defp pix_for(%Event{}), do: nil

  @impl true
  def handle_event("mark_paid", _params, socket) do
    %{event: event, row: row} = socket.assigns

    with %Attendee{} <- row,
         true <- Policy.can_toggle_paid?(event, row, policy_opts(socket)),
         {:ok, index} <-
           main_index(event, socket.assigns.participant_id, socket.assigns.user_id),
         {:ok, updated} <- Events.toggle_paid_main(event, index) do
      {:noreply,
       socket
       |> put_flash(:info, "Anotado! O organizador vê que você pagou.")
       |> assign_event(updated)
       |> to_event(updated)}
    else
      _ -> {:noreply, to_event(socket, event)}
    end
  end

  defp main_index(%Event{main_list: list}, participant_id, user_id) do
    case Enum.find_index(list, &Attendee.owns?(&1, participant_id, user_id)) do
      nil -> :error
      index -> {:ok, index + 1}
    end
  end

  defp policy_opts(socket) do
    [
      admin?: socket.assigns.current_admin?,
      organizer?:
        Participant.organizer?(
          %{"organizer_tokens" => socket.assigns[:organizer_tokens] || %{}},
          socket.assigns.event
        ),
      participant_id: socket.assigns.participant_id,
      current_user_id: socket.assigns.user_id
    ]
  end

  defp to_home(socket), do: push_navigate(socket, to: ~p"/")
  defp to_event(socket, event), do: push_navigate(socket, to: ~p"/r/#{event.slug}")

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
          <!-- RN-11: the app records a declaration, it does not verify a
               transfer, so the label describes what the person did elsewhere. -->
          <button
            :if={@row && not @row.paid}
            type="button"
            phx-click="mark_paid"
            class="w-full rounded-cta bg-ink px-4 py-4 text-[15px] font-bold text-ink-content shadow-cta transition-transform active:scale-[.97] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
          >
            Já fiz o Pix
          </button>

          <.link
            navigate={~p"/r/#{@event.slug}"}
            class="block w-full rounded-cta border-[1.5px] border-ink/15 px-4 py-3.5 text-center text-[15px] font-bold text-ink"
          >
            {if @row && @row.paid, do: "Ver a lista", else: "Pago depois"}
          </.link>
        </div>
      </:action>
      <div class="mx-auto flex min-h-full max-w-[420px] flex-col">
        <header>
          <p class="text-[11px] font-bold uppercase tracking-wide text-accent">Você está dentro</p>
          <h1 class="mt-1 text-2xl font-extrabold tracking-tight">{@event.title}</h1>
          <p :if={@row} class="mt-0.5 text-[13px] text-muted">
            {list_position_text(@event, @row)}
          </p>
        </header>

        <section
          :if={@pix}
          class="mt-5 rounded-card border border-hairline bg-base-100 p-5 shadow-card"
        >
          <p class="text-center text-[11px] font-semibold uppercase tracking-wide text-muted">
            Sua parte
          </p>
          <p class="mt-1 text-center text-[40px] font-extrabold leading-none tracking-tight">
            {@amount}
          </p>

          <!--
            Hero QR: big and on a dedicated white surface so it scans in
            dark mode too. `bg-qr-canvas` is a theme-invariant white token
            defined in `@theme`; a camera needs the light background under
            the dark modules regardless of what the app's theme is doing.
            The width matches the SVG we render into it, so the padding
            reads as a real quiet zone rather than negative space.
          -->
          <div class="mt-5 flex justify-center">
            <div
              id="pix-qr-canvas"
              class="rounded-card bg-qr-canvas p-4 shadow-sm [&>svg]:block [&>svg]:size-[256px]"
            >
              {raw(Pix.qr_svg(@pix.key, width: 256))}
            </div>
          </div>

          <div class="mt-4 space-y-2 text-center">
            <p class="text-[13px] font-bold text-ink">{@event.title}</p>
            <p class="font-mono text-[12px] text-muted">{@pix.display}</p>
            <p class="text-[11px] leading-snug text-muted">
              Aponte a câmera do banco no QR ou copie a chave.
            </p>
          </div>

          <!-- Readonly, not disabled: a disabled field cannot be focused
               or selected, which is the whole point of showing the key
               here. The canonical key is what a bank app accepts, so it
               is what gets copied — never the formatted version. -->
          <input
            type="text"
            readonly
            value={@pix.key}
            aria-label="Chave Pix para copiar"
            class="mt-3 w-full select-all rounded-row border border-hairline bg-canvas px-2 py-2 text-center font-mono text-[12px] text-ink focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent"
          />

          <button
            type="button"
            id="copy-pix-key"
            phx-hook=".CopyText"
            data-text={@pix.key}
            data-copied-label="Copiado!"
            class="mt-2 w-full text-center text-[12px] font-bold text-accent"
          >
            Copiar chave
          </button>
        </section>

        <div class="flex-1" />
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
        export default {
          mounted() {
            this.el.addEventListener("click", async () => {
              const text = this.el.dataset.text || ""
              const done = this.el.dataset.copiedLabel || "Copiado!"
              const original = this.el.innerText
              try {
                await navigator.clipboard.writeText(text)
              } catch (_) {
                // Older browsers and insecure origins have no clipboard API.
                const field = document.createElement("textarea")
                field.value = text
                document.body.appendChild(field)
                field.select()
                try { document.execCommand("copy") } catch (_) {}
                document.body.removeChild(field)
              }
              this.el.innerText = done
              setTimeout(() => { this.el.innerText = original }, 1500)
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp list_position_text(%Event{} = event, %Attendee{} = row) do
    if Enum.any?(event.wait_list, &(&1 == row)) do
      "Você está na espera — a vaga abre se alguém sair."
    else
      "Você está na lista principal."
    end
  end
end
