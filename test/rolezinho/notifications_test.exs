defmodule Rolezinho.NotificationsTest do
  use Rolezinho.DataCase, async: true
  use Oban.Testing, repo: Rolezinho.Repo

  alias Rolezinho.Accounts
  alias Rolezinho.Events
  alias Rolezinho.Groups
  alias Rolezinho.Notifications
  alias Rolezinho.Notifications.DeliverWorker
  alias Rolezinho.Notifications.NewEventWorker
  alias Rolezinho.Notifications.PushSubscription

  defp user(login) do
    {:ok, user} =
      Accounts.find_or_create_by_github(%{
        "github_id" => System.unique_integer([:positive]),
        "github_login" => login
      })

    user
  end

  defp group(overrides \\ %{}) do
    {:ok, group} =
      Groups.create(
        Map.merge(
          %{"name" => "Turma", "slug" => "nt-#{System.unique_integer([:positive])}"},
          overrides
        )
      )

    group
  end

  defp browser_sub(host \\ "fcm.googleapis.com", suffix \\ nil) do
    %{
      "endpoint" => "https://#{host}/fcm/send/#{suffix || System.unique_integer([:positive])}",
      "keys" => %{"p256dh" => "BPubKey", "auth" => "AuthSecret"}
    }
  end

  defp create_event(group, overrides \\ %{}, opts \\ []) do
    params =
      Map.merge(
        %{
          "title" => "Pelada",
          "slug" => "ev-#{System.unique_integer([:positive])}",
          "main_size" => "4",
          "wait_size" => "0"
        },
        overrides
      )

    {:ok, event} = Events.create(params, Keyword.merge([admin?: true, group_id: group.id], opts))
    event
  end

  describe "follow/3" do
    test "follows an open group, once" do
      u = user("f1")
      g = group()

      assert {:ok, _} = Notifications.follow(u, g)
      assert {:ok, _} = Notifications.follow(u, g)
      assert Notifications.following?(u.id, g.id)
    end

    test "refuses a password-protected group the user can't open" do
      u = user("f2")
      g = group(%{"password" => "segredo"})

      assert {:error, :forbidden} = Notifications.follow(u, g)

      assert {:ok, _} =
               Notifications.follow(u, g, unlocked_groups: MapSet.new([g.slug]))
    end

    test "unfollow stops it; anonymous callers never follow" do
      u = user("f3")
      g = group()
      {:ok, _} = Notifications.follow(u, g)
      :ok = Notifications.unfollow(u, g)

      refute Notifications.following?(u.id, g.id)
      refute Notifications.following?(nil, g.id)
    end
  end

  describe "register_device/3" do
    test "stores a device and rejects unknown push services" do
      u = user("d1")

      assert {:ok, %PushSubscription{}} = Notifications.register_device(u, browser_sub())
      assert {:error, changeset} = Notifications.register_device(u, browser_sub("evil.com"))
      assert "unsupported push service" in errors_on(changeset).endpoint
      assert Notifications.has_device?(u.id)
    end

    test "re-registering an endpoint moves it instead of duplicating" do
      a = user("d2a")
      b = user("d2b")
      sub = browser_sub("fcm.googleapis.com", "same")

      {:ok, first} = Notifications.register_device(a, sub)
      {:ok, second} = Notifications.register_device(b, sub)

      assert first.id == second.id
      assert second.user_id == b.id
      refute Notifications.has_device?(a.id)
    end

    test "keeps at most ten devices per user" do
      u = user("d3")
      for _ <- 1..12, do: {:ok, _} = Notifications.register_device(u, browser_sub())

      assert Repo.aggregate(from(s in PushSubscription, where: s.user_id == ^u.id), :count) == 10
    end
  end

  describe "announcing" do
    test "creating a visible event in a group queues the announcement" do
      g = group()
      event = create_event(g)

      assert_enqueued(worker: NewEventWorker, args: %{event_id: event.id})
    end

    test "a hidden event is announced when it's un-hidden, and only once" do
      g = group()
      event = create_event(g)
      Repo.delete_all(Oban.Job)

      {:ok, hidden} = Events.set_hidden(event, true)
      refute_enqueued(worker: NewEventWorker)

      {:ok, shown} = Events.set_hidden(hidden, false)
      assert_enqueued(worker: NewEventWorker, args: %{event_id: shown.id})

      {:ok, hidden} = Events.set_hidden(shown, true)
      {:ok, _} = Events.set_hidden(hidden, false)
      assert [_one] = all_enqueued(worker: NewEventWorker)
    end

    test "events outside a group are never announced" do
      {:ok, _event} =
        Events.create(
          %{
            "title" => "Solto",
            "slug" => "solto-#{System.unique_integer([:positive])}",
            "main_size" => "2",
            "wait_size" => "0"
          },
          admin?: true
        )

      refute_enqueued(worker: NewEventWorker)
    end
  end

  describe "NewEventWorker" do
    test "queues a delivery per device of followers who can open the group, minus the creator" do
      creator = user("w-creator")
      fan = user("w-fan")
      g = group()

      {:ok, _} = Notifications.follow(creator, g)
      {:ok, _} = Notifications.follow(fan, g)
      {:ok, _} = Notifications.register_device(creator, browser_sub())
      {:ok, fan_phone} = Notifications.register_device(fan, browser_sub())

      {:ok, fan_laptop} =
        Notifications.register_device(fan, browser_sub("updates.push.services.mozilla.com"))

      event =
        create_event(g, %{"title" => "Vôlei"}, created_by_user_id: creator.id, admin?: false)

      assert :ok = perform_job(NewEventWorker, %{event_id: event.id})

      queued =
        all_enqueued(worker: DeliverWorker)
        |> Enum.map(& &1.args["subscription_id"])
        |> Enum.sort()

      assert queued == Enum.sort([fan_phone.id, fan_laptop.id])

      [job | _] = all_enqueued(worker: DeliverWorker)
      payload = Jason.decode!(job.args["payload"])
      assert payload["title"] == "Novo rolê em Turma"
      assert payload["body"] =~ "Vôlei"
      assert payload["url"] =~ "/r/#{event.slug}"
    end

    test "skips followers who lost access to a password-protected group" do
      fan = user("w-locked")
      g = group(%{"password" => "segredo"})
      {:ok, _} = Notifications.follow(fan, g, unlocked_groups: MapSet.new([g.slug]))
      {:ok, _} = Notifications.register_device(fan, browser_sub())

      event = create_event(g)
      assert :ok = perform_job(NewEventWorker, %{event_id: event.id})

      refute_enqueued(worker: DeliverWorker)
    end

    test "does nothing for an event that was hidden again or deleted" do
      g = group()
      event = create_event(g)
      {:ok, _} = Events.set_hidden(event, true)

      assert :ok = perform_job(NewEventWorker, %{event_id: event.id})
      assert :ok = perform_job(NewEventWorker, %{event_id: -1})
      refute_enqueued(worker: DeliverWorker)
    end
  end

  describe "DeliverWorker" do
    test "delivers the payload to the device" do
      u = user("dw1")
      {:ok, sub} = Notifications.register_device(u, browser_sub())

      assert :ok = perform_job(DeliverWorker, %{subscription_id: sub.id, payload: "{}"})
      assert_received {:push_delivered, endpoint, "{}"}
      assert endpoint == sub.endpoint
    end

    test "deletes a device the push service dropped" do
      u = user("dw2")
      {:ok, sub} = Notifications.register_device(u, browser_sub("fcm.googleapis.com", "expired"))

      assert :ok = perform_job(DeliverWorker, %{subscription_id: sub.id, payload: "{}"})
      refute Notifications.has_device?(u.id)
    end

    test "returns an error for retryable failures, and ignores a deleted device" do
      u = user("dw3")
      {:ok, sub} = Notifications.register_device(u, browser_sub("fcm.googleapis.com", "flaky"))

      assert {:error, :service_unavailable} =
               perform_job(DeliverWorker, %{subscription_id: sub.id, payload: "{}"})

      assert :ok = perform_job(DeliverWorker, %{subscription_id: -1, payload: "{}"})
    end
  end
end
