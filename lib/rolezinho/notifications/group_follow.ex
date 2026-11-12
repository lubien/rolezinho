defmodule Rolezinho.Notifications.GroupFollow do
  @moduledoc """
  A signed-in user following a group: the bell on `/g/:slug`. Following is
  what decides *whether* someone hears about a new rolê in the group; the
  devices it reaches are the user's `PushSubscription`s.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Rolezinho.Accounts.User
  alias Rolezinho.Group

  schema "group_follows" do
    belongs_to :user, User
    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(%__MODULE__{} = follow) do
    follow
    |> change()
    |> unique_constraint([:user_id, :group_id])
  end
end
