defmodule Rolezinho.Notifications do
  @moduledoc """
  Push notifications for group followers: following a group, registering the
  devices that receive pushes, and announcing a newly published rolê.

  Only signed-in users take part — there is no anonymous identity a push
  subscription could belong to (ADR-0002).

  Announcing goes through Oban: `NewEventWorker` works out who should hear
  about the rolê (followers who can still open the group, minus its creator)
  and enqueues one `DeliverWorker` per device, so a slow or failing device
  retries on its own without holding up the rest.
  """

  import Ecto.Query

  alias Rolezinho.Accounts.User
  alias Rolezinho.Event
  alias Rolezinho.Group
  alias Rolezinho.Notifications.GroupFollow
  alias Rolezinho.Notifications.NewEventWorker
  alias Rolezinho.Notifications.PushSubscription
  alias Rolezinho.Repo

  # Enough for a phone, a laptop and a few browsers; past that the oldest
  # registration is dropped, so one account can't make every announcement fan
  # out to an unbounded list.
  defp max_devices_per_user, do: 10

  # ---------- Following ----------

  @doc """
  Follows `group` for `user`. Only a group the user can open may be followed:
  a password-protected group they haven't unlocked returns
  `{:error, :forbidden}`. Following twice is a no-op.
  """
  @spec follow(User.t(), Group.t(), keyword()) :: {:ok, GroupFollow.t()} | {:error, term()}
  def follow(%User{id: user_id}, %Group{id: group_id} = group, opts \\ []) do
    if Group.accessible?(
         group,
         Keyword.get(opts, :admin?, false),
         Keyword.get(opts, :unlocked_groups, MapSet.new()),
         user_id
       ) do
      %GroupFollow{user_id: user_id, group_id: group_id}
      |> GroupFollow.changeset()
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :group_id])
    else
      {:error, :forbidden}
    end
  end

  @doc "Stops following `group`. Not following is a no-op."
  @spec unfollow(User.t(), Group.t()) :: :ok
  def unfollow(%User{id: user_id}, %Group{id: group_id}) do
    from(f in GroupFollow, where: f.user_id == ^user_id and f.group_id == ^group_id)
    |> Repo.delete_all()

    :ok
  end

  @doc "Whether the user follows the group. Anonymous callers never do."
  @spec following?(integer() | nil, integer()) :: boolean()
  def following?(nil, _group_id), do: false

  def following?(user_id, group_id) when is_integer(user_id) and is_integer(group_id) do
    Repo.exists?(from f in GroupFollow, where: f.user_id == ^user_id and f.group_id == ^group_id)
  end

  # ---------- Devices ----------

  @doc """
  Registers (or refreshes) a device for `user` from what the browser's
  `PushManager.subscribe()` produced: `%{"endpoint" => ..., "keys" =>
  %{"p256dh" => ..., "auth" => ...}}`.

  An endpoint is unique per browser, so re-registering an endpoint already
  stored (a re-subscribe, or another account signing in on the same browser)
  moves it to this user rather than duplicating it.
  """
  @spec register_device(User.t(), map(), String.t() | nil) ::
          {:ok, PushSubscription.t()} | {:error, Ecto.Changeset.t()}
  def register_device(%User{id: user_id}, %{} = browser_subscription, user_agent \\ nil) do
    keys = Map.get(browser_subscription, "keys") || %{}

    attrs = %{
      "endpoint" => browser_subscription["endpoint"],
      "p256dh" => keys["p256dh"],
      "auth" => keys["auth"],
      "user_agent" => user_agent
    }

    existing =
      case attrs["endpoint"] do
        endpoint when is_binary(endpoint) -> Repo.get_by(PushSubscription, endpoint: endpoint)
        _ -> nil
      end

    result =
      (existing || %PushSubscription{})
      |> PushSubscription.changeset(attrs)
      |> Ecto.Changeset.put_change(:user_id, user_id)
      |> Repo.insert_or_update()

    with {:ok, _subscription} <- result, do: trim_devices(user_id)
    result
  end

  defp trim_devices(user_id) do
    stale_ids =
      from(s in PushSubscription,
        where: s.user_id == ^user_id,
        order_by: [desc: s.updated_at, desc: s.id],
        offset: ^max_devices_per_user(),
        select: s.id
      )
      |> Repo.all()

    from(s in PushSubscription, where: s.id in ^stale_ids) |> Repo.delete_all()
  end

  @doc "Whether the user has at least one registered device."
  @spec has_device?(integer() | nil) :: boolean()
  def has_device?(nil), do: false

  def has_device?(user_id) when is_integer(user_id),
    do: Repo.exists?(from s in PushSubscription, where: s.user_id == ^user_id)

  @doc false
  @spec delete_device(PushSubscription.t()) :: :ok
  def delete_device(%PushSubscription{id: id}) do
    from(s in PushSubscription, where: s.id == ^id) |> Repo.delete_all()
    :ok
  end

  # ---------- Announcing ----------

  @doc """
  Queues the announcement of a newly published rolê to its group's followers.

  Called when a grouped event becomes visible: created visible inside a
  group, or un-hidden. Anything else (no group, still hidden, not open for
  signups) is ignored here, and `NewEventWorker` checks again when it runs, in
  case the event changed in between.
  """
  @spec announce_event(Event.t()) :: {:ok, Oban.Job.t()} | :skipped | {:error, term()}
  def announce_event(%Event{} = event) do
    if announceable?(event) do
      %{event_id: event.id} |> NewEventWorker.new() |> Oban.insert()
    else
      :skipped
    end
  end

  @doc "Whether a rolê is in a state worth announcing."
  @spec announceable?(Event.t()) :: boolean()
  def announceable?(%Event{group_id: group_id, hidden: hidden, status: status}),
    do: is_integer(group_id) and not hidden and status in Event.open_statuses()

  @doc """
  The devices that should hear about `event`: every device of every follower
  of its group who can still open the group, except the event's creator.
  """
  @spec devices_to_notify(Event.t(), Group.t()) :: [PushSubscription.t()]
  def devices_to_notify(%Event{} = event, %Group{id: group_id} = group) do
    follower_ids =
      from(f in GroupFollow, where: f.group_id == ^group_id, select: f.user_id)
      |> Repo.all()
      |> Enum.reject(&(&1 == event.created_by_user_id))
      |> Enum.filter(&can_open?(group, &1))

    from(s in PushSubscription, where: s.user_id in ^follower_ids, order_by: [asc: s.id])
    |> Repo.all()
  end

  # Re-checked at send time: a follower who lost access (the password changed
  # and their unlock is gone) stops hearing about the group.
  defp can_open?(%Group{} = group, user_id),
    do:
      Group.accessible?(group, false, Rolezinho.Groups.unlocked_slugs_for_user(user_id), user_id)

  @doc """
  The notification payload the service worker (`priv/static/sw.js`) shows.
  """
  @spec payload(Event.t(), Group.t(), String.t()) :: String.t()
  def payload(%Event{} = event, %Group{} = group, url) do
    Jason.encode!(%{
      title: "Novo rolê em #{group.name}",
      body: payload_body(event),
      url: url,
      tag: "event-#{event.id}"
    })
  end

  defp payload_body(%Event{title: title, starts_at: nil}), do: String.trim(title)

  defp payload_body(%Event{title: title, starts_at: starts_at}) do
    # Stored in UTC, read in Brasília — same conversion as the home cards.
    when_text = starts_at |> DateTime.add(-3 * 3600, :second) |> Calendar.strftime("%d/%m · %Hh")
    "#{String.trim(title)} · #{when_text}"
  end
end
