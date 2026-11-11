defmodule Rolezinho.Repo.Migrations.AddAutoPromoteToEvents do
  use Ecto.Migration

  def change do
    alter table(:events) do
      # Opt-in: existing events keep manual promotion.
      add :auto_promote, :boolean, null: false, default: false
    end
  end
end
