defmodule Rolezinho.Notifications.Pusher do
  @moduledoc """
  Delivers one encrypted push message to one device. The implementation is
  chosen by config (`:rolezinho, :pusher`): Web Push in dev and prod, an
  in-memory one in tests.
  """

  alias Rolezinho.Notifications.PushSubscription

  @doc """
  Returns `:ok`, `{:error, :expired}` when the push service says the
  subscription is gone (the caller deletes it), or `{:error, reason}` for
  anything worth retrying.
  """
  @callback deliver(PushSubscription.t(), payload :: String.t()) ::
              :ok | {:error, :expired} | {:error, term()}

  @doc "The configured implementation."
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:rolezinho, :pusher)
end
