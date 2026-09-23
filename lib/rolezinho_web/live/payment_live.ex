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
    |> assign(:amount, Cash.format_amount(event.price_cents))
    |> assign(:pix, pix_for(event))
  end

  # Only the row this caller owns matters here — the screen is about settling
  # your own share (RN-12). Ownership matches by either identity (ADR-0002):
  # the per-device token, or the signed-in GitHub user.
  defp own_row(%Event{main_list: main, wait_list: wait}, participant_id, user_id) do
    (main ++ wait)
    |> Enum.find(&Attendee.owns?(&1, participant_id, user_id))
  end

  # The copy-and-paste code and the QR carry the same payload, amount included,
  # so the bank app opens with the value already filled in whichever way the
  # person pays. The bare key stays available for banks that want only the key.
  defp pix_for(%Event{pix_key: key, price_cents: cents}) when is_binary(key) and key != "" do
    case Pix.classify(key) do
      {:ok, _type, canonical} ->
        %{
          key: canonical,
          display: Pix.display(key) || key,
          code: Pix.brcode(canonical, amount_cents: cents),
          qr_svg: Pix.qr_svg(canonical, amount_cents: cents, width: 176)
        }

      :error ->
        nil
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
          <.action_button :if={@row && not @row.paid} phx-click="mark_paid">
            <.icon name="tabler-check" class="size-5" /> Já fiz o Pix
          </.action_button>

          <.action_button variant="outline" navigate={~p"/r/#{@event.slug}"}>
            {if @row && not @row.paid, do: "Pago depois", else: "Ver a lista"}
          </.action_button>
        </div>
      </:action>
      <div class="mx-auto flex min-h-full max-w-[420px] flex-col">
        <header>
          <p class="text-[11px] font-bold uppercase tracking-wide text-accent-ink">
            {if @row, do: "Você está dentro", else: "Pagamento"}
          </p>
          <h1 class="mt-1 text-2xl font-extrabold tracking-tight">{@event.title}</h1>
          <p :if={@row} class="mt-1 text-[13px] text-muted">
            {list_position_text(@event, @row)}
          </p>
        </header>

        <section
          :if={@pix}
          aria-labelledby="payment-amount-label"
          class="mt-5 rounded-card border border-hairline bg-base-100 p-5"
        >
          <div :if={@amount} class="text-center">
            <p
              id="payment-amount-label"
              class="text-[11px] font-bold uppercase tracking-wide text-muted"
            >
              Sua parte
            </p>
            <p class="mt-1 text-[40px] font-extrabold leading-none tracking-tight">{@amount}</p>
          </div>

          <p
            :if={@row && @row.paid}
            class="mt-4 flex items-center justify-center gap-1.5 rounded-row bg-tint px-3 py-2.5 text-[13px] font-bold text-accent-ink"
          >
            <.icon name="tabler-circle-check-filled" class="size-5" /> Você marcou como pago
          </p>

          <ol class={["space-y-4", @amount && "mt-5"]}>
            <li>
              <p class="text-[13px] font-bold">
                <span class="text-accent-ink">1.</span> Copie o código Pix
              </p>
              <button
                type="button"
                id="copy-pix-code"
                phx-hook=".CopyText"
                data-text={@pix.code}
                data-copied-label="Código copiado!"
                class="mt-2 flex min-h-12 w-full items-center justify-center gap-2 rounded-cta bg-tint px-4 py-3 text-[15px] font-bold text-ink transition-transform active:scale-[.97] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
              >
                <.icon name="tabler-copy" class="size-5 text-accent-ink" />
                <span data-label aria-live="polite">Copiar código Pix</span>
              </button>
            </li>
            <li>
              <p class="text-[13px] font-bold">
                <span class="text-accent-ink">2.</span> Cole no app do banco
              </p>
              <p class="mt-0.5 text-[13px] text-muted">
                Use a opção "Pix copia e cola"{if @amount,
                  do: " — o valor já vem preenchido",
                  else: ""}.
              </p>
            </li>
          </ol>

          <div class="mt-5 flex items-center gap-3 rounded-row border border-hairline px-3 py-2">
            <div class="min-w-0 flex-1">
              <p class="text-[11px] font-bold text-muted">Ou use só a chave</p>
              <p class="truncate font-mono text-[15px] font-semibold text-ink">{@pix.display}</p>
            </div>
            <button
              type="button"
              id="copy-pix-key"
              phx-hook=".CopyText"
              data-text={@pix.key}
              data-copied-label="Copiada!"
              aria-label={"Copiar chave Pix #{@pix.display}"}
              class="inline-flex min-h-11 shrink-0 items-center gap-1 rounded-row px-2 text-[13px] font-bold text-accent-ink focus-visible:outline-2 focus-visible:outline-accent"
            >
              <.icon name="tabler-copy" class="size-4" />
              <span data-label aria-live="polite">Copiar</span>
            </button>
          </div>

          <.pix_qr
            svg={@pix.qr_svg}
            caption="Pagando de outro celular? Escaneie o QR."
            class="mt-5 border-t border-ink/8 pt-5"
          />
        </section>

        <div class="flex-1" />
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
        export default {
          mounted() {
            // Only the label changes, so the icon beside it survives the swap.
            const label = this.el.querySelector("[data-label]") || this.el
            this.el.addEventListener("click", async () => {
              const text = this.el.dataset.text || ""
              const done = this.el.dataset.copiedLabel || "Copiado!"
              const original = label.textContent
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
              label.textContent = done
              clearTimeout(this.reset)
              this.reset = setTimeout(() => { label.textContent = original }, 1500)
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
