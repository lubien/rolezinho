defmodule Rolezinho.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  @moduledoc """
  REST API keys (2026-10 ADR amendment).

  Only the SHA-256 hash of the raw token lands in the DB. The raw
  token is shown to the user once at creation time and never again;
  if they lose it, they revoke the key and create a new one.

  `key_prefix` stores the first ~16 chars of the raw token
  (`rk_live_abc12345`) for UI identification \u2014 enough to tell two
  keys apart in a list, not enough to authenticate.

  `permissions` is a Postgres text array of scope strings like
  `events:read`, `events:write`, `groups:read`, `groups:write`,
  `participants:read`, `participants:write`. Validation of the
  allowed set lives on the schema.

  `revoked_at` is a nullable timestamp instead of a hard delete so
  the audit trail \"this key was active then\" survives revocation.
  Lookup filters by `revoked_at IS NULL`.
  """

  def change do
    create table(:api_keys) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :key_hash, :binary, null: false
      add :key_prefix, :string, null: false
      add :permissions, {:array, :string}, null: false, default: []
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:user_id])
    create index(:api_keys, [:user_id, :revoked_at])
  end
end
