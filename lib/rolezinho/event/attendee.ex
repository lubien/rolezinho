defmodule Rolezinho.Event.Attendee do
  @moduledoc """
  A single spot in a list (may be empty). Embedded in `Rolezinho.Event`.

  Ownership travels with the row through one of two identities, both
  optional and both set at the moment the row is created:

    * `participant_id` — an opaque per-device token the browser holds in a
      signed cookie. Clearing cookies loses the claim. This is the only
      identity for an anonymous visitor.
    * `user_id` — the signed-in GitHub user who joined (ADR-0002). Survives
      cookie clears and travels across devices: whoever signs in with the
      same GitHub account gets their rows back.

  A row can have neither (grandfathered rows created before identity
  existed), either (anonymous with a token; or a signed-in user with no
  token because they never held one), or both (typical: signed in AND
  their session held the token).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :name, :string, default: ""
    field :paid, :boolean, default: false
    # What this person spent on the rolê, for the "Dividir no final" split
    # method (`Rolezinho.Event.Settlement`). Ignored by every other method.
    field :contributed_cents, :integer, default: 0
    # Where this person wants to receive their money back under "Dividir no
    # final". Kept as typed: canonicalizing would guess, and a bare 11-digit
    # phone would come back as a CPF (see `Rolezinho.Pix.display_as/2`).
    field :pix_key, :string

    field :participant_id, :string
    field :user_id, :integer
    field :joined_at, :utc_datetime

    # Answers to the organizer's custom fields. Scoped to the event; visible
    # on `/r/:slug` to anyone who can see the list at all (behind the same
    # unlock gate that hides names on a password-protected event). Editable
    # by admin, organizer, and the attendee themselves — see
    # `Event.Policy.can_edit_row?/3`.
    field :values, :map, default: %{}
  end

  @type t :: %__MODULE__{
          name: String.t(),
          paid: boolean(),
          contributed_cents: non_neg_integer(),
          pix_key: String.t() | nil,
          participant_id: String.t() | nil,
          user_id: integer() | nil,
          joined_at: DateTime.t() | nil,
          values: map()
        }

  def changeset(attendee, params \\ %{}) do
    attendee
    |> cast(params, [
      :name,
      :paid,
      :contributed_cents,
      :pix_key,
      :participant_id,
      :user_id,
      :joined_at,
      :values
    ])
    |> validate_length(:name, max: 60)
    |> validate_number(:contributed_cents, greater_than_or_equal_to: 0)
    |> validate_length(:pix_key, max: 100)
  end

  @doc """
  Returns true when this spot belongs to the given participant token.

  A blank id never matches: an empty slot, or a row created before identity
  existed, must not be claimable by a browser that happens to send nothing.
  """
  @spec owned_by?(t(), String.t() | nil) :: boolean()
  def owned_by?(%__MODULE__{participant_id: id}, participant_id)
      when is_binary(id) and is_binary(participant_id) and id != "" and participant_id != "" do
    Plug.Crypto.secure_compare(id, participant_id)
  end

  def owned_by?(%__MODULE__{}, _), do: false

  @doc """
  Returns true when this spot belongs to the given signed-in user.

  A row with no `user_id` (anonymous join) is never claimed by anyone via
  this path — those rows only respond to the participant token.
  """
  @spec owned_by_user?(t(), integer() | nil) :: boolean()
  def owned_by_user?(%__MODULE__{user_id: uid}, user_id)
      when is_integer(uid) and is_integer(user_id) and uid == user_id,
      do: true

  def owned_by_user?(%__MODULE__{}, _), do: false

  @doc """
  Returns true when the caller owns this spot, by either identity.

  Used everywhere the UI asks "is this mine?": the row is mine if my
  browser holds the participant token, OR if I am signed in as the user
  the row was created under.
  """
  @spec owns?(t(), String.t() | nil, integer() | nil) :: boolean()
  def owns?(%__MODULE__{} = attendee, participant_id, user_id) do
    owned_by?(attendee, participant_id) or owned_by_user?(attendee, user_id)
  end

  @doc """
  Canonicalizes a name so two typings of the same person collapse to one
  suggestion in the autocomplete: leading/trailing whitespace trimmed,
  internal whitespace collapsed to a single space, each word capitalized.

  Word-cap is naive on purpose — Portuguese-language personal names are
  the vast majority of what this app sees, and the cost of getting a
  "de"/"da" wrong here (they render capitalized in a suggestion) is much
  smaller than the cost of missing a dedup between "Pedro costa" and
  "pedro Costa".

  ## Examples

      iex> Rolezinho.Event.Attendee.canonical_name("  pedro   costa  ")
      "Pedro Costa"

      iex> Rolezinho.Event.Attendee.canonical_name("PEDRO COSTA")
      "Pedro Costa"

      iex> Rolezinho.Event.Attendee.canonical_name("")
      ""
  """
  @spec canonical_name(String.t() | nil) :: String.t()
  def canonical_name(nil), do: ""

  def canonical_name(value) when is_binary(value) do
    value
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map_join(" ", &capitalize_word/1)
  end

  def canonical_name(_), do: ""

  # `String.capitalize/1` lowercases the rest of the word, which is what
  # we want (so "MARIA" → "Maria" instead of "MARIA"). Preserves Unicode.
  defp capitalize_word(word), do: String.capitalize(word)
end
