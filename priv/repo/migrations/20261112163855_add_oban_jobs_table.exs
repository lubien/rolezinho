defmodule Rolezinho.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up()

  # Down to version 1 drops the whole Oban schema.
  def down, do: Oban.Migration.down(version: 1)
end
