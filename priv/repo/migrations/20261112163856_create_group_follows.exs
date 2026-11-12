defmodule Rolezinho.Repo.Migrations.CreateGroupFollows do
  use Ecto.Migration

  def change do
    create table(:group_follows) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_follows, [:user_id, :group_id])
    create index(:group_follows, [:group_id])
  end
end
