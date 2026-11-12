defmodule Rolezinho.Notifications.DeliverWorker do
  @moduledoc """
  Sends one push message to one device, retrying transient failures. A
  device the push service reports as gone (404/410) is deleted instead.
  """
  use Oban.Worker, queue: :push, max_attempts: 5

  alias Rolezinho.Notifications
  alias Rolezinho.Notifications.PushSubscription
  alias Rolezinho.Notifications.Pusher
  alias Rolezinho.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => id, "payload" => payload}}) do
    case Repo.get(PushSubscription, id) do
      %PushSubscription{} = subscription -> deliver(subscription, payload)
      nil -> :ok
    end
  end

  defp deliver(%PushSubscription{} = subscription, payload) do
    case Pusher.impl().deliver(subscription, payload) do
      :ok -> :ok
      {:error, :expired} -> Notifications.delete_device(subscription)
      {:error, reason} -> {:error, reason}
    end
  end
end
