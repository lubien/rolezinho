defmodule Rolezinho.Notifications.TestPusher do
  @moduledoc """
  In-memory `Rolezinho.Notifications.Pusher` for tests. Sends
  `{:push_delivered, endpoint, payload}` to the calling process (Oban runs
  jobs inline in the test process under `perform_job/2` and `drain_queue/1`).

  An endpoint containing `"expired"` answers like a push service that dropped
  the subscription; one containing `"flaky"` fails with a retryable error.
  """
  @behaviour Rolezinho.Notifications.Pusher

  @impl true
  def deliver(subscription, payload) do
    cond do
      String.contains?(subscription.endpoint, "expired") ->
        {:error, :expired}

      String.contains?(subscription.endpoint, "flaky") ->
        {:error, :service_unavailable}

      true ->
        send(self(), {:push_delivered, subscription.endpoint, payload})
        :ok
    end
  end
end
