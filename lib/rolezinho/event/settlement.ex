defmodule Rolezinho.Event.Settlement do
  @moduledoc """
  The payment plan for the "Dividir no final" split method (`:settle_up`).

  Nobody sets a price. Each person on the main list records what they spent
  (`Attendee.contributed_cents`); the total is split equally among everyone on
  the list, and the plan says who sends how much to whom so everyone ends even.

      Ana R$ 200, Bruno R$ 120, 8 others R$ 0 → R$ 320 ÷ 10 = R$ 32 each
      Ana is owed R$ 168, Bruno R$ 88, the other 8 owe R$ 32 each

  Someone who spent less than their share owes the difference like anyone
  else, and someone who spent exactly their share is out of the plan.

  Everything is integer cents. When the total does not divide evenly, the
  leftover cents go one each to the first people on the list, so shares
  always add up to the total and transfers always add up to what is owed.

  Transfers are built greedily — the largest debt pays the largest credit
  first — which never takes more than `people - 1` transfers. Ties keep list
  order, so the plan is stable while nobody changes their numbers.

  Like `Rolezinho.Event.Cash`, this works on declarations only: the app never
  moves money, and `paid` on a debtor means "says they sent their part".
  """

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee

  @type person :: %{
          index: pos_integer(),
          name: String.t(),
          paid: boolean(),
          contributed_cents: non_neg_integer(),
          pix_key: String.t() | nil,
          share_cents: non_neg_integer(),
          balance_cents: integer()
        }

  @type transfer :: %{
          from: person(),
          to: person(),
          cents: pos_integer()
        }

  @type plan :: %{
          total_cents: non_neg_integer(),
          share_cents: non_neg_integer() | nil,
          people: [person()],
          transfers: [transfer()]
        }

  @doc """
  Builds the plan for the event's main list. `index` is the 1-based position
  in `main_list`, the same position the list operations take.

  `share_cents` is the base share (leftover cents land on the first people),
  or `nil` while the list is empty.
  """
  @spec plan(Event.t()) :: plan()
  def plan(%Event{main_list: list}) do
    filled =
      list
      |> Enum.with_index(1)
      |> Enum.reject(fn {%Attendee{name: name}, _index} -> String.trim(name) == "" end)

    total = Enum.reduce(filled, 0, fn {attendee, _}, sum -> sum + contributed(attendee) end)
    count = length(filled)
    shares = shares(total, count)

    people =
      filled
      |> Enum.zip(shares)
      |> Enum.map(fn {{attendee, index}, share} ->
        %{
          index: index,
          name: attendee.name,
          paid: attendee.paid,
          contributed_cents: contributed(attendee),
          pix_key: attendee.pix_key,
          share_cents: share,
          balance_cents: contributed(attendee) - share
        }
      end)

    %{
      total_cents: total,
      share_cents: if(count > 0, do: div(total, count)),
      people: people,
      transfers: transfers(people)
    }
  end

  @doc """
  Groups the plan's transfers by who sends them, in list order — one entry per
  debtor, which is how the shared text reads ("Hugo manda R$ 8 para Ana e
  R$ 24 para Bruno").
  """
  @spec by_sender(plan()) :: [{person(), [transfer()]}]
  def by_sender(%{transfers: transfers}) do
    transfers
    |> Enum.group_by(& &1.from.index)
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.map(fn {_index, [first | _] = group} -> {first.from, group} end)
  end

  @doc """
  The people the plan has receiving money, in list order — whose Pix keys a
  payer needs.
  """
  @spec receivers(plan()) :: [person()]
  def receivers(%{transfers: transfers}) do
    transfers |> Enum.map(& &1.to) |> Enum.uniq_by(& &1.index) |> Enum.sort_by(& &1.index)
  end

  defp contributed(%Attendee{contributed_cents: cents}) when is_integer(cents) and cents > 0,
    do: cents

  defp contributed(%Attendee{}), do: 0

  defp shares(_total, 0), do: []

  defp shares(total, count) do
    base = div(total, count)
    leftover = rem(total, count)
    Enum.map(1..count, fn position -> if position <= leftover, do: base + 1, else: base end)
  end

  defp transfers(people) do
    debtors =
      people
      |> Enum.filter(&(&1.balance_cents < 0))
      |> Enum.map(&{&1, -&1.balance_cents})
      |> sort_largest_first()

    creditors =
      people
      |> Enum.filter(&(&1.balance_cents > 0))
      |> Enum.map(&{&1, &1.balance_cents})
      |> sort_largest_first()

    match(debtors, creditors, [])
  end

  defp sort_largest_first(entries),
    do: Enum.sort_by(entries, fn {person, amount} -> {-amount, person.index} end)

  defp match([], _creditors, acc), do: Enum.reverse(acc)
  defp match(_debtors, [], acc), do: Enum.reverse(acc)

  defp match([{debtor, owes} | debtors], [{creditor, owed} | creditors], acc) do
    cents = min(owes, owed)
    acc = [%{from: debtor, to: creditor, cents: cents} | acc]

    debtors = if owes > cents, do: [{debtor, owes - cents} | debtors], else: debtors
    creditors = if owed > cents, do: [{creditor, owed - cents} | creditors], else: creditors

    match(debtors, creditors, acc)
  end
end
