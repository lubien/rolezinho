defmodule RolezinhoWeb.Api.V1.AuthController do
  @moduledoc """
  `GET /api/v1/auth/whoami` — sanity check for the client.

  Returns which user owns the key and which scopes it carries, so a
  consumer debugging an integration can confirm "I'm authenticated,
  and I have the permissions I expect" without having to probe a
  real resource endpoint.

  No scope required — any valid key reaches this endpoint. That's
  the point: it tells you what you have.
  """
  use RolezinhoWeb, :controller

  alias Rolezinho.Accounts.ApiKey
  alias Rolezinho.Accounts.User

  def whoami(conn, _params) do
    %User{} = user = conn.assigns.current_user
    %ApiKey{} = key = conn.assigns.current_api_key

    json(conn, %{
      user: %{
        id: user.id,
        username: user.username,
        display_name: User.display_name(user)
      },
      key: %{
        id: key.id,
        name: key.name,
        prefix: key.key_prefix,
        permissions: key.permissions
      }
    })
  end
end
