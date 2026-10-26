defmodule Rolezinho.Accounts.ApiKey do
  @moduledoc """
  REST API key for the local-auth user, scoped by granular permissions.

  Two identities travel per request to the API:

    * the owning `User` (via `:user_id`), and
    * the key itself (via `key_hash`).

  Storage is the SHA-256 of the raw token. The raw token is handed
  to the user once at creation time (via `Accounts.create_api_key/2`'s
  second tuple element) and never recoverable from the DB again.

  ## Permissions

  Each key carries a list of scope strings. The allowed set is a
  closed enumeration: anything the schema's `cast_permissions/1`
  doesn't recognise is rejected at insert time, so a hostile POST
  can't invent new scopes.

  | Scope | Covers |
  |---|---|
  | `events:read` | list / get events (owned + participated-in) |
  | `events:write` | create / update / delete events (owned only) |
  | `groups:read` | list / get groups (owned only) |
  | `groups:write` | create / update / delete groups (owned only) |
  | `participants:read` | list participants (owned + participated-in) |
  | `participants:write` | add / edit / remove / promote (owned only) |

  There is no `admin` scope \u2014 per product decision (2026-10),
  the API never widens past the key's owner, even for platform
  admins. A platform admin who wants API-side control of other
  people's events uses the UI or SSHs in.

  ## Revocation

  A revoked key stays on the row with `:revoked_at` set rather than
  being deleted. Keeps the \"was this key ever active\" history
  queryable. Authentication filters it out.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Rolezinho.Accounts.User

  @all_scopes ~w(
    events:read
    events:write
    groups:read
    groups:write
    participants:read
    participants:write
  )

  schema "api_keys" do
    field :name, :string
    field :key_hash, :binary
    field :key_prefix, :string
    field :permissions, {:array, :string}, default: []
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          key_hash: binary() | nil,
          key_prefix: String.t() | nil,
          permissions: [String.t()],
          last_used_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          user_id: integer() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t()
        }

  @doc "The closed set of allowed scope strings."
  def all_scopes, do: @all_scopes

  @doc """
  Changeset used at insert time.

  `:user_id`, `:key_hash`, `:key_prefix` are set by the context from
  server-side state and should never arrive from user input. `:name`
  and `:permissions` are the user-facing fields.
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:user_id, :name, :key_hash, :key_prefix, :permissions])
    # Trim before validate_required so a whitespace-only name is
    # rejected with the same "obrigatório" message as a nil one.
    |> update_change(:name, &trim_or_nil/1)
    |> validate_required([:user_id, :key_hash, :key_prefix])
    |> validate_required([:name], message: "obrigatório")
    |> validate_length(:name, min: 1, max: 100)
    |> cast_permissions()
    |> unique_constraint(:key_hash)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Changeset for marking a key as revoked."
  def revoke_changeset(%__MODULE__{} = key, now) do
    change(key, %{revoked_at: DateTime.truncate(now, :second)})
  end

  @doc "Changeset for recording the key was just used."
  def touch_changeset(%__MODULE__{} = key, now) do
    change(key, %{last_used_at: DateTime.truncate(now, :second)})
  end

  @doc """
  Returns true when the key has an **active** scope matching `scope`.

  A revoked key never has any scope. This is the one check callers
  need; permissions-vs-ownership is a separate concern (the
  controller resolves that).
  """
  @spec has_scope?(t(), String.t()) :: boolean()
  def has_scope?(%__MODULE__{revoked_at: nil, permissions: scopes}, scope)
      when is_binary(scope) do
    scope in scopes
  end

  def has_scope?(_, _), do: false

  defp trim_or_nil(nil), do: nil

  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      other -> other
    end
  end

  defp trim_or_nil(_), do: nil

  # Rejects scopes we don't recognise. Casts to a deduplicated,
  # ordered list so two keys with the same effective permissions
  # serialize the same way, which keeps diffs readable.
  defp cast_permissions(changeset) do
    case get_change(changeset, :permissions) do
      nil ->
        changeset

      list when is_list(list) ->
        {valid, invalid} =
          list
          |> Enum.map(&to_string/1)
          |> Enum.uniq()
          |> Enum.split_with(&(&1 in @all_scopes))

        changeset = put_change(changeset, :permissions, Enum.sort(valid))

        if invalid == [],
          do: changeset,
          else:
            add_error(
              changeset,
              :permissions,
              "escopo inv\u00e1lido: #{Enum.join(invalid, ", ")}"
            )

      _ ->
        add_error(changeset, :permissions, "deve ser uma lista")
    end
  end
end
