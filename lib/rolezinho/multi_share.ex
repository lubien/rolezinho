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

  The same selection also ships as a shareable image (`to_image_rows/1`): one
  row per event with its title, place, start time, count, and status tag.
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

  @typedoc "One row of the shareable image."
  @type image_row :: %{
          title: String.t(),
          place: String.t() | nil,
          when: String.t() | nil,
          count: non_neg_integer(),
          total: non_neg_integer(),
          tag: String.t() | nil
        }

  @doc """
  The rows of the shareable image for `events`, in the given order.

  The count follows the text: filled/capacity, or paid/filled for
  `:payments_only`. The image is meant for public posts, so it never carries a
  password — and a password-protected event leaves its place out too, since
  the place is part of what the password gates.
  """
  @spec to_image_rows([Event.t()]) :: [image_row()]
  def to_image_rows(events) when is_list(events), do: Enum.map(events, &image_row/1)

  defp image_row(%Event{} = event) do
    {count, total} = image_count(event)

    %{
      title: String.trim(event.title || ""),
      place: image_place(event),
      when: image_when(event.starts_at),
      count: count,
      total: total,
      tag: image_tag(event.status)
    }
  end

  defp image_count(%Event{status: :payments_only} = event) do
    filled = filled(event)
    {Enum.count(filled, & &1.paid), length(filled)}
  end

  defp image_count(%Event{} = event), do: {length(filled(event)), event.main_capacity}

  defp image_place(%Event{} = event) do
    place = String.trim(event.local || "")
    if place == "" or Event.password_protected?(event), do: nil, else: place
  end

  defp image_tag(:payments_only), do: "Apenas pagamentos"
  defp image_tag(:maybe), do: Event.maybe_status_label()
  defp image_tag(_status), do: nil

  defp image_when(nil), do: nil

  # Stored in UTC, read in Brasília — same offset the home cards use.
  defp image_when(%DateTime{} = starts_at) do
    local = DateTime.add(starts_at, -3 * 3600, :second)
    weekday = Enum.at(weekday_names(), Date.day_of_week(local) - 1)
    hour = if local.minute == 0, do: "%Hh", else: "%Hh%M"

    Calendar.strftime(local, "#{weekday}, %d/%m · #{hour}")
  end

  defp weekday_names, do: ~w(Seg Ter Qua Qui Sex Sáb Dom)

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
