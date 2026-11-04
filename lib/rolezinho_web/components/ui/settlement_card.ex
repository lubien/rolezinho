defmodule RolezinhoWeb.Components.UI.SettlementCard do
  @moduledoc """
  The "Dividir no final" card: the total, each person's share, the payment
  plan, and what everyone spent.

  The plan comes from `Rolezinho.Event.Settlement`; this only draws it. A
  transfer whose sender has marked ✅ is struck through, so the screen reads
  as a checklist of what is still open.

  Rows in `editable` get an inline field for what that person spent. The
  LiveView decides which rows those are, with the same rule the server
  enforces when the form arrives — this is an affordance, not the gate.
  """
  use Phoenix.Component

  import RolezinhoWeb.CoreComponents, only: [input: 1]

  alias Rolezinho.Event.Cash
  alias Rolezinho.Event.Settlement

  @doc """
  Renders the card.

  ## Examples

      <.settlement_card plan={Settlement.plan(@event)} editable={MapSet.new([3])} />
  """
  attr :plan, :map, required: true, doc: "a `Rolezinho.Event.Settlement.plan/1` result"
  attr :editable, :any, default: MapSet.new(), doc: "1-based indexes the viewer may edit"
  attr :id, :string, default: "settlement"
  attr :class, :any, default: nil

  def settlement_card(assigns) do
    assigns = assign(assigns, :groups, Settlement.by_sender(assigns.plan))

    ~H"""
    <section id={@id} class={["rounded-card border border-hairline bg-base-100 p-4", @class]}>
      <h2 class="text-[10px] font-semibold uppercase tracking-wide text-muted">Dividir no final</h2>
      <p class="mt-1 text-2xl font-extrabold tracking-tight">
        {Cash.format_amount(@plan.total_cents) || "R$ 0"}
      </p>
      <p :if={@plan.share_cents} class="text-[12px] text-muted">
        {Cash.format_amount(@plan.share_cents) || "R$ 0"} por pessoa · {length(@plan.people)} pessoas
      </p>

      <div :if={@groups != []} id={"#{@id}-plan"} class="mt-4">
        <h3 class="text-[10px] font-semibold uppercase tracking-wide text-muted">
          Plano de pagamento
        </h3>
        <ul class="mt-1 divide-y divide-hairline">
          <li
            :for={{sender, transfers} <- @groups}
            id={"#{@id}-sender-#{sender.index}"}
            class={["flex items-start gap-2 py-2 text-[13px]", sender.paid && "text-muted"]}
          >
            <span class={["min-w-0 flex-1", sender.paid && "line-through"]}>
              <span class="font-semibold">{sender.name}</span>
              manda
              <%= for {transfer, position} <- Enum.with_index(transfers) do %>
                <span :if={position > 0}> e </span>
                <span class="font-bold tabular-nums">{Cash.format_amount(transfer.cents)}</span>
                para <span class="font-semibold">{transfer.to.name}</span>
              <% end %>
            </span>
            <span :if={sender.paid} aria-label="já mandou">✅</span>
          </li>
        </ul>
      </div>

      <p
        :if={@groups == [] and @plan.total_cents > 0}
        class="mt-3 rounded-row bg-tint px-3 py-2.5 text-[12px]"
      >
        Tudo certo: ninguém precisa mandar nada.
      </p>
      <p
        :if={@plan.total_cents == 0 and @plan.people != []}
        class="mt-3 rounded-row bg-tint px-3 py-2.5 text-[12px] leading-relaxed"
      >
        Ninguém informou gastos ainda. Quem pagou algo coloca o valor abaixo.
      </p>

      <div :if={@plan.people != []} class="mt-4">
        <h3 class="text-[10px] font-semibold uppercase tracking-wide text-muted">
          Quem pagou o quê
        </h3>
        <ul class="mt-1 divide-y divide-hairline">
          <li :for={person <- @plan.people} id={"#{@id}-person-#{person.index}"} class="py-2">
            <div class="flex items-center gap-2 text-[13px]">
              <span class="min-w-0 flex-1 truncate font-semibold">{person.name}</span>
              <span class="tabular-nums">
                {Cash.format_amount(person.contributed_cents) || "R$ 0"}
              </span>
              <.balance_pill person={person} />
            </div>
            <div
              :if={person.balance_cents > 0 and person.pix_key}
              class="mt-1 flex items-center gap-2 rounded-row bg-tint px-2.5 py-1.5"
            >
              <span class="text-[10px] font-semibold uppercase tracking-wide text-muted">Pix</span>
              <span class="min-w-0 flex-1 truncate font-mono text-[12px]">{person.pix_key}</span>
              <button
                type="button"
                id={"#{@id}-copy-pix-#{person.index}"}
                phx-hook=".CopyPix"
                data-text={person.pix_key}
                class="shrink-0 text-[12px] font-bold text-accent-ink"
              >
                Copiar
              </button>
            </div>
            <%!-- One compact row: the person's name above already says whose
                 amount this is, so the labels are for screen readers only. --%>
            <form
              :if={MapSet.member?(@editable, person.index)}
              id={"contribution-form-#{person.index}"}
              phx-submit="set_contribution"
              class="mt-1.5 flex items-start gap-2"
            >
              <input type="hidden" name="index" value={person.index} />
              <div class="min-w-0 flex-1">
                <.input
                  id={"contribution-amount-#{person.index}"}
                  name="amount"
                  value={amount_input(person.contributed_cents)}
                  placeholder="Quanto pagou? ex.: 120"
                  inputmode="decimal"
                  aria-label={"Quanto #{person.name} pagou"}
                />
                <%!-- Only someone who spent something can end up being paid
                     back, so that is when the key is worth asking for. Not a
                     password: the attributes keep password managers out, as
                     on the organizer's Pix field. --%>
                <.input
                  :if={person.contributed_cents > 0}
                  id={"contribution-pix-#{person.index}"}
                  name="pix_key"
                  value={person.pix_key || ""}
                  placeholder="Chave Pix pra receber"
                  aria-label={"Chave Pix de #{person.name}"}
                  autocomplete="off"
                  data-1p-ignore="true"
                  data-lpignore="true"
                  data-bwignore="true"
                />
              </div>
              <button
                type="submit"
                class="h-[38px] shrink-0 rounded-row bg-ink px-4 text-xs font-bold text-ink-content"
              >
                Salvar
              </button>
            </form>
          </li>
        </ul>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyPix">
        export default {
          mounted() {
            this.el.addEventListener("click", async () => {
              const original = this.el.textContent
              try {
                await navigator.clipboard.writeText(this.el.dataset.text || "")
                this.el.textContent = "Copiado!"
              } catch (_) {
                this.el.textContent = "Não deu"
              }
              setTimeout(() => { this.el.textContent = original }, 1500)
            })
          }
        }
      </script>
    </section>
    """
  end

  attr :person, :map, required: true

  defp balance_pill(%{person: %{balance_cents: balance}} = assigns) when balance > 0 do
    ~H"""
    <span class="rounded-full bg-info/15 px-2 py-0.5 text-[10px] font-bold text-info">
      recebe {Cash.format_amount(@person.balance_cents)}
    </span>
    """
  end

  defp balance_pill(%{person: %{balance_cents: balance, paid: true}} = assigns)
       when balance < 0 do
    ~H"""
    <span class="rounded-full bg-success/15 px-2 py-0.5 text-[10px] font-bold text-success">
      mandou ✅
    </span>
    """
  end

  defp balance_pill(%{person: %{balance_cents: balance}} = assigns) when balance < 0 do
    ~H"""
    <span class="rounded-full bg-danger/10 px-2 py-0.5 text-[10px] font-bold text-danger">
      manda {Cash.format_amount(-@person.balance_cents)}
    </span>
    """
  end

  defp balance_pill(assigns) do
    ~H"""
    <span class="rounded-full bg-ink/[0.06] px-2 py-0.5 text-[10px] font-bold text-muted">
      quite
    </span>
    """
  end

  defp amount_input(0), do: ""

  defp amount_input(cents) do
    reais = div(cents, 100)

    case rem(cents, 100) do
      0 -> Integer.to_string(reais)
      centavos -> "#{reais},#{String.pad_leading(Integer.to_string(centavos), 2, "0")}"
    end
  end
end
