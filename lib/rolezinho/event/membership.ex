defmodule Rolezinho.Event.Membership do
  @moduledoc """
  What the viewer is to an event, for the home listing: on the list, on the
  waiting list, owing money, or running it.

  The viewer is identified the same two ways the event page uses — the
  per-device `participant_id` for this event, or the signed-in `user_id`
  (`Attendee.owns?/3`) — and the organizer flag is decided by the caller,
  which holds the session's organizer tokens.

  When several apply, the most urgent wins: owing money, then being on a list,
  then organizing.
  """

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.Cash
  alias Rolezinho.Event.Settlement

  @type status :: :caloteiro | :participating | :waiting | :organizing | nil

  @doc """
  Returns the viewer's status on `event`, or `nil` when they have no part in it.

  `:caloteiro` is for a "Só pagamentos" event where the viewer holds an unpaid
  main-list row that owes something: a free event owes nothing, and under
  "Dividir no final" only someone the plan has sending money owes.
  """
  @spec status(Event.t(), String.t() | nil, integer() | nil, boolean()) :: status()
  def status(%Event{} = event, participant_id, user_id, organizer?) do
    main_rows = owned_indexes(event.main_list, participant_id, user_id)

    cond do
      main_rows != [] and owes?(event, main_rows) -> :caloteiro
      main_rows != [] -> :participating
      owned_indexes(event.wait_list, participant_id, user_id) != [] -> :waiting
      organizer? -> :organizing
      true -> nil
    end
  end

  defp owned_indexes(list, participant_id, user_id) do
    for {%Attendee{name: name} = attendee, index} <- Enum.with_index(list, 1),
        String.trim(name) != "",
        Attendee.owns?(attendee, participant_id, user_id),
        do: index
  end

  defp owes?(%Event{status: :payments_only, split_method: :settle_up} = event, indexes) do
    event
    |> Settlement.plan()
    |> Map.fetch!(:people)
    |> Enum.any?(&(&1.index in indexes and &1.balance_cents < 0 and not &1.paid))
  end

  defp owes?(%Event{status: :payments_only} = event, indexes) do
    is_integer(Cash.per_person_cents(event)) and
      Enum.any?(indexes, &(not Enum.at(event.main_list, &1 - 1).paid))
  end

  defp owes?(%Event{}, _indexes), do: false
end
