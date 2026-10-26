defmodule RolezinhoWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token auth for the REST API.

  Pulls the token out of the `Authorization: Bearer <token>` header,
  resolves it to a `{user, api_key}` pair via
  `Rolezinho.Accounts.authenticate_api_key/1`, consults the per-key
  rate limiter, and either:

    * assigns `:current_user` + `:current_api_key` and continues, or
    * halts with a JSON error (`401`, `429`).

  Per the API design doc, this plug does **not** check scopes — that
  happens in the controller, which has the context (which action is
  being performed) to decide. All this plug guarantees is "there is
  a non-revoked key behind this request, and it hasn't exceeded its
  rate limit".

  Side effect on success: `last_used_at` is stamped on the key
  asynchronously via `Task.start/1` so the request path doesn't
  wait on the DB write.
  """
  import Plug.Conn

  alias Rolezinho.Accounts
  alias Rolezinho.Accounts.ApiKey
  alias Rolezinho.Accounts.ApiRateLimiter
  alias Rolezinho.Accounts.User

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- fetch_token(conn),
         {:ok, %User{} = user, %ApiKey{id: key_id} = key} <- Accounts.authenticate_api_key(token) do
      case ApiRateLimiter.check(key_id) do
        :ok ->
          # Fire-and-forget: last_used_at is a convenience,
          # not something a request should block on.
          _ = Task.start(fn -> Accounts.touch_api_key(key) end)

          conn
          |> assign(:current_user, user)
          |> assign(:current_api_key, key)
          |> put_rate_limit_headers(key_id)

        {:error, :rate_limited, retry_after} ->
          conn
          |> put_rate_limit_headers(key_id)
          |> put_resp_header("retry-after", Integer.to_string(retry_after))
          |> error_response(
            429,
            "rate_limited",
            "Too many requests. Retry in #{retry_after}s."
          )
      end
    else
      _ -> unauthorized(conn)
    end
  end

  defp fetch_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    error_response(
      conn,
      401,
      "unauthorized",
      "Missing or invalid API key. Send `Authorization: Bearer <key>`."
    )
  end

  defp put_rate_limit_headers(conn, key_id) do
    {minute, day} = ApiRateLimiter.remaining(key_id)

    conn
    |> put_resp_header("x-ratelimit-remaining-minute", Integer.to_string(minute))
    |> put_resp_header("x-ratelimit-remaining-day", Integer.to_string(day))
  end

  defp error_response(conn, status, type, message) do
    body = Jason.encode!(%{error: %{type: type, message: message}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
