defmodule Rolezinho.MultiShare do
  @moduledoc """
  Builds the "Rolezinhos ativos" message: several events bundled into one
  text an organizer can paste into a group chat.

      Rolezinhos ativos

      * Vôlei: 12/18. https://rolezinho.lubien.dev/r/volei
      * Churras: Apenas pagamentos 11/12. https://rolezinho.lubien.dev/r/churras
      * Coworking: Averiguando Resenha 03/08. https://rolezinho.lubien.dev/r/coworking

  Each line carries the status label (none for `:active`) and a count:
  filled/capacity, except `:payments_only`, which shows paid/filled — once
  signups close, what matters is who still owes.
  """

  alias Rolezinho.Event

  @doc """
  Renders the message for `events`, in the given order.

  `url_fun` turns an event into its public URL.

  Opts:

    * `:include_password` — when true, password-protected events get a
      `Senha: <password>` suffix on their line.
  """
  @spec to_text([Event.t()], (Event.t() -> String.t()), keyword()) :: String.t()
  def to_text(events, url_fun, opts \\ []) when is_list(events) do
    include_password? = Keyword.get(opts, :include_password, false)
    lines = Enum.map(events, &line(&1, url_fun.(&1), include_password?))

    Enum.join([title() | ["" | lines]], "\n") <> "\n"
  end

  defp title, do: "Rolezinhos ativos"

  defp line(%Event{} = event, url, include_password?) do
    base = "* #{String.trim(event.title || "")}: #{summary(event)}. #{url}"

    if include_password? and Event.password_protected?(event),
      do: "#{base} Senha: #{event.password}",
      else: base
  end

  defp summary(%Event{status: :payments_only} = event) do
    filled = filled(event)
    "Apenas pagamentos #{count(Enum.count(filled, & &1.paid), length(filled))}"
  end

  defp summary(%Event{status: :maybe} = event),
    do: "#{Event.maybe_status_label()} #{count(length(filled(event)), event.main_capacity)}"

  defp summary(%Event{} = event), do: count(length(filled(event)), event.main_capacity)

  defp filled(%Event{main_list: list}), do: Enum.reject(list, &(String.trim(&1.name) == ""))

  defp count(part, total), do: "#{pad(part)}/#{pad(total)}"

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
