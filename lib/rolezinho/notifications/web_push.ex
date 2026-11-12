defmodule Rolezinho.Notifications.WebPush do
  @moduledoc """
  `Rolezinho.Notifications.Pusher` over the Web Push protocol (VAPID), via
  `web_push_elixir`. Keys come from `:web_push_elixir` config — see
  `config/runtime.exs` for production.
  """
  @behaviour Rolezinho.Notifications.Pusher

  alias Rolezinho.Notifications.PushSubscription

  # A day: a phone that's off for a while still gets the news when it's back,
  # but nobody learns about yesterday's rolê next week.
  defp ttl_seconds, do: 60 * 60 * 24

  @impl true
  def deliver(%PushSubscription{} = subscription, payload) when is_binary(payload) do
    json =
      Jason.encode!(%{
        endpoint: subscription.endpoint,
        keys: %{p256dh: subscription.p256dh, auth: subscription.auth}
      })

    case WebPushElixir.send_notification(json, payload, ttl: ttl_seconds(), urgency: :normal) do
      {:ok, _response} -> :ok
      {:error, :expired} -> {:error, :expired}
      {:error, reason} -> {:error, reason}
    end
  end
end
