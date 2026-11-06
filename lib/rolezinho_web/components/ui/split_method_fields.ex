defmodule RolezinhoWeb.Components.UI.SplitMethodFields do
  @moduledoc """
  The "Método de separação" picker and the amount field that goes with it.

  The amount field follows the method: the whole bill for "Dividir
  automaticamente total", a per-person price for the two per-participant
  methods, and nothing for "Dividir no final", where each attendee records
  what they spent instead. The info button opens a sheet explaining the four
  options with one example each — organizers pick this once, so the
  explanation lives one tap away rather than on the form.

  Expects a form with `split_method`, `price`, and `total` fields, and a
  `phx-change` on the parent form so the amount field swaps as the select
  changes.
  """
  use Phoenix.Component

  import RolezinhoWeb.CoreComponents, only: [input: 1, icon: 1]
  import RolezinhoWeb.Components.UI.BottomSheet, only: [bottom_sheet: 1]

  alias Rolezinho.Event
  alias RolezinhoWeb.Components.UI.BottomSheet

  @doc """
  Renders the picker, the matching amount field, and the help sheet.

  ## Examples

      <.split_method_fields form={@form} />
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :id, :string, default: "split-method", doc: "prefix for the DOM ids"

  def split_method_fields(assigns) do
    assigns = assign(assigns, :method, current_method(assigns.form[:split_method].value))

    ~H"""
    <div id={@id} class="space-y-3">
      <div>
        <div class="mb-1 flex items-center gap-1.5">
          <label for={@form[:split_method].id} class="text-sm font-semibold">
            Método de separação
          </label>
          <button
            type="button"
            id={"#{@id}-help-btn"}
            phx-click={BottomSheet.show("#{@id}-help")}
            class="grid size-8 place-items-center rounded-full text-muted focus-visible:outline-2 focus-visible:outline-accent"
            aria-label="Como funciona cada método"
          >
            <.icon name="tabler-info-circle" class="size-[18px]" />
          </button>
        </div>
        <.input
          field={@form[:split_method]}
          type="select"
          options={
            Enum.map(Event.split_methods(), &{Event.split_method_label(&1), Atom.to_string(&1)})
          }
        />
      </div>

      <.input
        :if={@method == :total_split}
        field={@form[:total]}
        label="Total do rolê"
        placeholder="ex.: 300"
      />
      <.input
        :if={@method in [:per_person, :per_seat]}
        field={@form[:price]}
        label="Quanto cada um paga"
        placeholder="ex.: 15"
      />
      <p
        :if={@method == :settle_up}
        class="rounded-row bg-tint px-3 py-2.5 text-[12px] leading-relaxed"
      >
        Sem preço fixo. Cada pessoa informa quanto pagou e o app monta quem manda quanto pra quem.
      </p>

      <.bottom_sheet id={"#{@id}-help"} title="Como dividir a conta">
        <dl class="divide-y divide-hairline">
          <div :for={{method, text, example} <- explanations()} class="py-2.5 first:pt-0">
            <dt class="text-[13px] font-bold">{Event.split_method_label(method)}</dt>
            <dd class="mt-0.5 text-[12px] leading-relaxed text-muted">{text}</dd>
            <dd class="mt-1 inline-block rounded-row bg-tint px-2 py-1 font-mono text-[11px] text-ink">
              {example}
            </dd>
          </div>
        </dl>
      </.bottom_sheet>
    </div>
    """
  end

  defp explanations do
    [
      {:total_split, "Você informa o total. O app divide por quem está na lista.",
       "R$ 300 ÷ 12 = R$ 25 cada"},
      {:per_person, "Cada pessoa paga o mesmo valor fixo.", "R$ 15 × 12 = R$ 180"},
      {:per_seat, "Igual ao anterior, mas vagas vazias contam como faltando.",
       "12/18 → faltam 6 × R$ 15"},
      {:settle_up, "Cada um diz quanto gastou. O app iguala tudo com o mínimo de Pix.",
       "Carla manda R$ 32 pra Ana"}
    ]
  end

  defp current_method(method) when is_atom(method) and not is_nil(method), do: method
  defp current_method("total_split"), do: :total_split
  defp current_method("per_seat"), do: :per_seat
  defp current_method("settle_up"), do: :settle_up
  defp current_method(_), do: :per_person
end
