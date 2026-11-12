defmodule Rolezinho.Notifications.NewEventWorker do
  @moduledoc """
  Fans an announced rolê out to one `DeliverWorker` job per device that
  should hear about it (`Rolezinho.Notifications.devices_to_notify/2`).

  Unique per event for a day, so creating and then un-hiding, or toggling
  "Oculto" back and forth, announces a rolê once.
  """
  use Oban.Worker,
    queue: :push,
    max_attempts: 3,
    unique: [period: 60 * 60 * 24, keys: [:event_id], states: :all]

  alias Rolezinho.Event
  alias Rolezinho.Notifications
  alias Rolezinho.Notifications.DeliverWorker
  alias Rolezinho.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) do
    case Repo.get(Event, event_id) |> Repo.preload(:group) do
      %Event{group: %Rolezinho.Group{} = group} = event ->
        if Notifications.announceable?(event), do: fan_out(event, group)
        :ok

      _deleted_or_ungrouped ->
        :ok
    end
  end

  defp fan_out(%Event{} = event, group) do
    payload =
      Notifications.payload(event, group, RolezinhoWeb.Endpoint.url() <> "/r/" <> event.slug)

    event
    |> Notifications.devices_to_notify(group)
    |> Enum.map(&DeliverWorker.new(%{subscription_id: &1.id, payload: payload}))
    |> Oban.insert_all()
  end
end
