defmodule Rolezinho.EventsAutoPromoteTest do
  use Rolezinho.DataCase, async: true

  alias Rolezinho.Events

  defp create(overrides) do
    params =
      Map.merge(
        %{
          "title" => "Pelada",
          "slug" => "ap-#{System.unique_integer([:positive])}",
          "main_size" => "2",
          "wait_size" => "3",
          "auto_promote" => "true"
        },
        overrides
      )

    {:ok, event} = Events.create(params, admin?: true)

    Enum.reduce(~w(Ana Bia Caio Duda), event, fn name, acc ->
      {:ok, acc, _} = Events.add_party(acc, name, 1, [])
      acc
    end)
  end

  defp names(list), do: list |> Enum.map(& &1.name) |> Enum.reject(&(&1 == ""))

  test "create stores the setting; it defaults to off" do
    assert create(%{}).auto_promote
    refute create(%{"auto_promote" => nil}).auto_promote
  end

  test "removing someone from the main list promotes the head of the queue" do
    event = create(%{})
    assert names(event.wait_list) == ["Caio", "Duda"]

    {:ok, event} = Events.remove_main(event, 1)

    assert names(event.main_list) == ["Bia", "Caio"]
    assert names(event.wait_list) == ["Duda"]
  end

  test "with the setting off, the spot stays open" do
    {:ok, event} = Events.remove_main(create(%{"auto_promote" => "false"}), 1)

    assert names(event.main_list) == ["Bia"]
    assert names(event.wait_list) == ["Caio", "Duda"]
  end

  test "a payments-only event doesn't promote" do
    event = create(%{})
    {:ok, event} = Events.set_status(event, :payments_only)
    {:ok, event} = Events.remove_main(event, 1)

    assert names(event.wait_list) == ["Caio", "Duda"]
  end

  test "raising the capacity doesn't promote anyone" do
    {:ok, event} = Events.resize_lists(create(%{}), 4, true)

    assert names(event.main_list) == ["Ana", "Bia"]
    assert names(event.wait_list) == ["Caio", "Duda"]
  end

  test "resize_lists toggles the setting and keeps it when not given" do
    event = create(%{"auto_promote" => "false"})

    {:ok, event} = Events.resize_lists(event, 2, true, auto_promote: true)
    assert event.auto_promote

    {:ok, event} = Events.resize_lists(event, 2, true)
    assert event.auto_promote
  end

  test "clearing names through a chat update promotes into the freed spots" do
    event = create(%{})

    {:ok, event} =
      Events.apply_chat_update(event, %{main: %{1 => %{"name" => ""}, 2 => %{"name" => ""}}})

    assert names(event.main_list) == ["Caio", "Duda"]
    assert event.wait_list == []
  end

  test "a chat update that swaps a name frees nothing" do
    event = create(%{})
    {:ok, event} = Events.apply_chat_update(event, %{main: %{1 => %{"name" => "Zeca"}}})

    assert names(event.main_list) == ["Zeca", "Bia"]
    assert names(event.wait_list) == ["Caio", "Duda"]
  end
end
