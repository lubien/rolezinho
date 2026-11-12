defmodule Rolezinho.Notifications.PushSubscription do
  @moduledoc """
  One browser on one device that agreed to receive push notifications for a
  signed-in user, as handed over by the browser's `PushManager.subscribe()`.

  The endpoint is a URL our server will POST to, supplied by a client — the
  textbook server-side request forgery shape. So it is accepted only over
  `https` and only on the push services browsers actually use (see
  `push_hosts/0`). It also works as a bearer secret for that device, so it
  is never rendered back.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Rolezinho.Accounts.User

  schema "push_subscriptions" do
    belongs_to :user, User
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    field :user_agent, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  Casts what the browser sent. `user_id` is set by the caller, never cast.
  """
  def changeset(%__MODULE__{} = subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth, :user_agent])
    |> validate_required([:endpoint, :p256dh, :auth])
    |> validate_length(:endpoint, max: 1000)
    |> validate_length(:p256dh, max: 200)
    |> validate_length(:auth, max: 100)
    |> update_change(:user_agent, &String.slice(&1, 0, 255))
    |> validate_change(:endpoint, fn :endpoint, endpoint ->
      if allowed_endpoint?(endpoint), do: [], else: [endpoint: "unsupported push service"]
    end)
    |> unique_constraint(:endpoint)
  end

  @doc """
  True for an `https` URL on a known browser push service, on the default
  port. Everything else would turn our server into a client for arbitrary
  hosts.
  """
  @spec allowed_endpoint?(String.t()) :: boolean()
  def allowed_endpoint?(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, port: 443, userinfo: nil} when is_binary(host) ->
        host = String.downcase(host)
        Enum.any?(push_hosts(), &(host == &1 or String.ends_with?(host, "." <> &1)))

      %URI{} ->
        false
    end
  end

  def allowed_endpoint?(_), do: false

  # Chrome/Edge-on-Android (FCM), Firefox (Mozilla autopush), Safari and iOS
  # home-screen apps (Apple), and Edge on Windows (WNS).
  defp push_hosts do
    [
      "fcm.googleapis.com",
      "android.googleapis.com",
      "updates.push.services.mozilla.com",
      "push.services.mozilla.com",
      "web.push.apple.com",
      "notify.windows.com"
    ]
  end
end
