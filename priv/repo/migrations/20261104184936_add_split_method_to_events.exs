defmodule Rolezinho.Repo.Migrations.AddSplitMethodToEvents do
  use Ecto.Migration

  def change do
    alter table(:events) do
      # Existing rows keep today's behavior: a fixed price per person.
      add :split_method, :string, null: false, default: "per_person"
      add :total_cents, :integer
    end
  end
end
