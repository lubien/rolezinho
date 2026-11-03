defmodule Rolezinho.EventsShareableTest do
  use Rolezinho.DataCase, async: true

  alias Rolezinho.Accounts
  alias Rolezinho.Events

  defp create_user(login) do
    {:ok, user} =
      Accounts.find_or_create_by_github(%{
        "github_id" => System.unique_integer([:positive]),
        "github_login" => login
      })

    user
  end

  defp create_event(user, slug) do
    {:ok, event} =
      Events.create(%{"title" => "Rolê", "slug" => slug, "main_size" => "3", "wait_size" => "0"},
        admin?: false,
        created_by_user_id: user.id
      )

    event
  end

  describe "list_shareable_for/1" do
    test "returns the user's non-done events, hidden ones included" do
      owner = create_user("shareable-owner")
      other = create_user("shareable-other")

      mine = create_event(owner, "shareable-mine")
      hidden = create_event(owner, "shareable-hidden")
      {:ok, _} = Events.set_hidden(hidden, true)
      done = create_event(owner, "shareable-done")
      {:ok, _} = Events.set_status(done, :done)
      create_event(other, "shareable-theirs")

      slugs = owner.id |> Events.list_shareable_for() |> Enum.map(& &1.slug) |> Enum.sort()

      assert slugs == Enum.sort([mine.slug, hidden.slug])
    end

    test "returns nothing for an anonymous caller" do
      assert Events.list_shareable_for(nil) == []
    end
  end
end
