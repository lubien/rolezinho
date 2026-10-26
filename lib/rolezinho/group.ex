defmodule Rolezinho.Group do
  @moduledoc """
  A bundle of events that share a page at `/g/:slug`.

  A group has a slug (immutable after creation, per product spec), a name, an
  optional password and a visibility flag. Public groups appear on the home
  page; hidden ones are reachable only by direct URL. Events belonging to a
  group never appear on the home page — the group is what represents them.

  The password mirrors the event password (SECURITY.md §3): plaintext by
  deliberate decision, because it is shared in the same message that carries
  the link and must be readable back. It is friction, not secrecy.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Rolezinho.Event
  alias Rolezinho.Group

  @visibilities [:public, :hidden]

  @slug_regex Event.slug_regex()

  schema "groups" do
    field :slug, :string
    field :name, :string, default: ""
    field :password, :string
    field :visibility, Ecto.Enum, values: @visibilities, default: :public

    has_many :events, Event

    # Optional signed-in creator (ADR-0002). NULL for groups created before
    # accounts existed. A creator gets full edit rights on their group
    # without needing the group password — see `editable_by?/4`.
    belongs_to :created_by_user, Rolezinho.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @type visibility :: :public | :hidden

  @type t :: %__MODULE__{
          id: integer() | nil,
          slug: String.t() | nil,
          name: String.t(),
          password: String.t() | nil,
          visibility: visibility(),
          created_by_user_id: integer() | nil,
          events: [Event.t()] | Ecto.Association.NotLoaded.t()
        }

  @doc "Valid visibility values."
  def visibilities, do: @visibilities

  @doc "Returns true when the group has a password set."
  @spec password_protected?(t()) :: boolean()
  def password_protected?(%Group{password: p}) when is_binary(p) and p != "", do: true
  def password_protected?(%Group{}), do: false

  @doc """
  Returns true when the caller has enough access to see the group's contents
  (name, event list, etc.) — as opposed to the unlock panel only.

  Four paths grant access:

    * admin (the environment-wide bypass),
    * the group has no password at all,
    * the caller is the signed-in creator (ADR-0002 durable identity),
    * the caller has the group's slug in the session unlock set (which,
      for a signed-in user, has already been merged with their persisted
      unlocks by `RolezinhoWeb.Plugs.User`).

  `current_user_id` is optional so the old three-arg call sites still
  compile; they lose only the creator-bypass path.
  """
  @spec accessible?(t(), boolean(), MapSet.t(), integer() | nil) :: boolean()
  def accessible?(
        %Group{} = group,
        admin?,
        %MapSet{} = unlocked_groups,
        current_user_id \\ nil
      ) do
    cond do
      admin? -> true
      not password_protected?(group) -> true
      created_by?(group, current_user_id) -> true
      MapSet.member?(unlocked_groups, group.slug) -> true
      true -> false
    end
  end

  @doc """
  Returns true when the caller may edit the group (rename, change password,
  add events into it).

  There are three ways to earn edit access:

    * be the platform admin,
    * be the signed-in user whose id matches `created_by_user_id` (ADR-0002),
    * or, on a password-protected group, hold the unlock in the session.

  A passwordless group with no creator user (grandfathered pre-ADR-0002) is
  admin-only — there is no bearer secret left to check.
  """
  @spec editable_by?(t(), boolean(), MapSet.t(), integer() | nil) :: boolean()
  def editable_by?(
        %Group{} = group,
        admin?,
        %MapSet{} = unlocked_groups,
        current_user_id \\ nil
      ) do
    cond do
      admin? ->
        true

      created_by?(group, current_user_id) ->
        true

      password_protected?(group) and MapSet.member?(unlocked_groups, group.slug) ->
        true

      true ->
        false
    end
  end

  @doc """
  Narrower than `editable_by?/4`: returns true only for the platform
  admin or the group's own creator.

  Used where a piece of state must not leak to *unlocked-but-not-
  owning* visitors even if they can otherwise edit the group. The
  motivating case is hidden events on the group page (2026-09): a
  visitor holding the unlock can see and edit the group but must
  not see events the owner deliberately hid — those stay reachable
  only by direct URL, exactly like on the home page.
  """
  @spec owned_by?(t(), boolean(), integer() | nil) :: boolean()
  def owned_by?(%Group{} = group, admin?, current_user_id \\ nil) do
    cond do
      admin? -> true
      created_by?(group, current_user_id) -> true
      true -> false
    end
  end

  defp created_by?(%Group{created_by_user_id: same}, same) when is_integer(same), do: true
  defp created_by?(_group, _user_id), do: false

  # Mass-assignment-protected: the creator id is set by the controller from the
  # session, never cast from params. Mirrors `Event.put_created_by_user_id/2`.
  @doc false
  def put_created_by_user_id(%Group{} = group, nil),
    do: Ecto.Changeset.change(group, created_by_user_id: nil)

  def put_created_by_user_id(%Group{} = group, id) when is_integer(id),
    do: Ecto.Changeset.change(group, created_by_user_id: id)

  @doc """
  Full changeset used by the `Rolezinho.Groups` context to persist groups.

  Notes:
    * `slug` is only cast on insertion (a new struct); on update it is stripped
      because the product rule says the slug never changes.
    * `password` normalizes empty/whitespace to `nil`, mirroring events.
  """
  def changeset(%Group{} = group, attrs) do
    fields =
      if is_nil(group.id) do
        [:slug, :name, :password, :visibility]
      else
        # Immutable after creation — no rename, no admin override. This mirrors
        # the spec: "Group slugs never change once created."
        [:name, :password, :visibility]
      end

    group
    |> cast(attrs, fields)
    |> update_change(:password, &normalize_password/1)
    |> update_change(:name, &normalize_name/1)
    |> maybe_downcase_slug()
    |> validate_required([:slug, :name, :visibility])
    |> validate_length(:name, min: 3, max: 80)
    |> validate_format(:slug, @slug_regex, message: "use letras minúsculas, números e traços")
    |> validate_length(:password, max: 80)
    |> unique_constraint(:slug, message: "já está em uso")
  end

  defp maybe_downcase_slug(changeset) do
    case get_change(changeset, :slug) do
      nil -> changeset
      slug -> put_change(changeset, :slug, slug |> String.trim() |> String.downcase())
    end
  end

  defp normalize_password(nil), do: nil

  defp normalize_password(str) when is_binary(str) do
    case String.trim(str) do
      "" -> nil
      other -> other
    end
  end

  defp normalize_password(_), do: nil

  defp normalize_name(nil), do: ""
  defp normalize_name(str) when is_binary(str), do: String.trim(str)
  defp normalize_name(_), do: ""
end
