defmodule Rolezinho.Event.Policy do
  @moduledoc """
  Who may do what to an event and its rows.

  This is the permission matrix from the product spec, in one place, so a screen
  never decides for itself. Hiding a button is presentation; these functions are
  the decision, and a privileged `handle_event` has to call one of them even
  when the template already hid the control — a socket message can be sent
  without the button existing.

  The roles are ordered: `:admin` (environment-wide support bypass) can do
  whatever `:organizer` can, which can do whatever a `:participant` can on their
  own row. A `:visitor` may only read and join.

  | Action              | Visitor | Participant | Organizer |
  |---------------------|---------|-------------|-----------|
  | join a list         | yes     | yes         | yes       |
  | mark own payment    | no      | own row     | any row   |
  | mark another's      | no      | no          | yes       |
  | leave the list      | no      | own row     | any row   |
  | remove someone      | no      | no          | yes       |
  | promote from wait   | no      | no          | yes       |
  | edit details        | no      | no          | yes       |
  | close the event     | no      | no          | yes       |
  """

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee

  @type role :: :visitor | :participant | :organizer | :admin

  @doc """
  Resolves the caller's role for this event.

  Three ways to earn the organizer role (ADR-0002):

    * hold the environment-wide admin secret (`:admin?`),
    * hold the event's `organizer_token` in the session (`:organizer?`),
    * or be signed in as the user who created the event
      (`current_user_id == event.created_by_user_id`).

  A participant is anyone who owns a row on this event, by either identity
  (the per-device `participant_id` token, or the signed-in `user_id`). A
  visitor is everybody else.
  """
  @spec role(Event.t(), keyword()) :: role()
  def role(%Event{} = event, opts) do
    cond do
      Keyword.get(opts, :admin?, false) -> :admin
      Keyword.get(opts, :organizer?, false) -> :organizer
      created_by?(event, Keyword.get(opts, :current_user_id)) -> :organizer
      holds_a_row?(event, opts) -> :participant
      true -> :visitor
    end
  end

  # ADR-0002: a signed-in user whose id matches `created_by_user_id` gets
  # organizer rights over that one event, without holding the token. This is
  # how organizer identity survives across devices once the creator has an
  # account.
  defp created_by?(%Event{created_by_user_id: same}, same) when is_integer(same), do: true
  defp created_by?(_event, _user_id), do: false

  @doc """
  Returns true when the caller may flip the paid check on `attendee`.

  RN-12: a participant only ever marks their own row — the check is a statement
  about money they say they sent, so nobody else gets to make it for them.
  RN-13: the organizer may mark anyone, being the one who sees the money arrive.

  A participant can prove ownership by either identity today: the per-device
  `participant_id` token, or being signed in as the row's `user_id`.
  """
  @spec can_toggle_paid?(Event.t(), Attendee.t(), keyword()) :: boolean()
  def can_toggle_paid?(%Event{} = event, %Attendee{} = attendee, opts) do
    case role(event, opts) do
      role when role in [:organizer, :admin] -> true
      :participant -> owns?(attendee, opts)
      :visitor -> false
    end
  end

  @doc """
  Returns true when the caller may take `attendee` off the list.

  RN-21: a participant removes only themselves. Confirmation is still required
  either way (RN-22), but that is the screen's job, not this one's.
  """
  @spec can_remove?(Event.t(), Attendee.t(), keyword()) :: boolean()
  def can_remove?(%Event{} = event, %Attendee{} = attendee, opts) do
    case role(event, opts) do
      role when role in [:organizer, :admin] -> true
      :participant -> owns?(attendee, opts)
      :visitor -> false
    end
  end

  @doc """
  Returns true when the caller may edit `attendee`'s name and form answers.

  Same permission set as `can_remove?/3`: admin and organizer can edit any
  row; a participant can edit their own row (by either identity). Fixing a
  typo in your own name or answer is not a decision anyone else should have
  to gate.

  Kept as a dedicated function rather than reusing `can_remove?` so call
  sites read as what they do — the two decisions may diverge later (a
  frozen event that no longer accepts removals could still allow edits, or
  vice-versa) and there is no risk of one bug becoming two.
  """
  @spec can_edit_row?(Event.t(), Attendee.t(), keyword()) :: boolean()
  def can_edit_row?(%Event{} = event, %Attendee{} = attendee, opts) do
    case role(event, opts) do
      role when role in [:organizer, :admin] -> true
      :participant -> owns?(attendee, opts)
      :visitor -> false
    end
  end

  @doc """
  Returns true when the caller may edit the event itself.

  RN-23: title, location, time, price and the Pix key belong to the organizer.
  """
  @spec can_edit?(Event.t(), keyword()) :: boolean()
  def can_edit?(%Event{} = event, opts), do: role(event, opts) in [:organizer, :admin]

  @doc """
  Returns true when the caller may promote someone from the waiting list.

  RN-31: promotion is the organizer's decision. The queue moves on its own only
  when the organizer opted into `auto_promote`, and then only into the spots a
  removal frees (`Rolezinho.Event.fill_from_waitlist/2`) — an empty slot from a
  capacity change still waits for someone to promote.
  """
  @spec can_promote?(Event.t(), keyword()) :: boolean()
  def can_promote?(%Event{} = event, opts), do: role(event, opts) in [:organizer, :admin]

  @doc """
  Returns true when someone may still join.

  Invariant 6: a closed event accepts nobody, whoever is asking. `payments_only`
  keeps the same meaning it has today — signups shut, payments still tracked —
  and the organizer stays able to add people by hand.
  """
  @spec can_join?(Event.t(), keyword()) :: boolean()
  def can_join?(%Event{status: :done}, _opts), do: false

  def can_join?(%Event{} = event, opts) do
    not Event.locked_signups?(event) or role(event, opts) in [:organizer, :admin]
  end

  # "Holds a row" now considers both identities: the per-device token, or
  # the signed-in user id. Either one earning ownership on any row means the
  # caller is a participant on this event.
  defp holds_a_row?(%Event{} = event, opts) do
    participant_id = Keyword.get(opts, :participant_id)
    user_id = Keyword.get(opts, :current_user_id)

    cond do
      is_nil(participant_id) and is_nil(user_id) -> false
      participant_id == "" and is_nil(user_id) -> false
      true -> Enum.any?(all_attendees(event), &Attendee.owns?(&1, participant_id, user_id))
    end
  end

  # The ownership check the per-row policy calls use. `opts` carries both
  # identity keys; `Attendee.owns?/3` short-circuits on the first match.
  defp owns?(%Attendee{} = attendee, opts) do
    Attendee.owns?(
      attendee,
      Keyword.get(opts, :participant_id),
      Keyword.get(opts, :current_user_id)
    )
  end

  defp all_attendees(%Event{main_list: main, wait_list: wait}) do
    Enum.filter(main ++ wait, &match?(%Attendee{}, &1))
  end
end
