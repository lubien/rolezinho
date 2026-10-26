defmodule RolezinhoWeb.Plugs.ApiResponseHeaders do
  @moduledoc """
  Response hardening for the REST API pipeline.

  Sets two headers on every API response, success or error:

    * `x-content-type-options: nosniff` — stops a browser from
      MIME-sniffing a JSON response into HTML (which would open up a
      very narrow XSS vector if a payload ever happened to look like
      HTML).
    * `cache-control: private, no-store` — API responses are bound
      to a specific API key's permissions and (frequently) to that
      key's owner's data. A shared cache (CDN, corporate proxy)
      caching a response and serving it to another request would be
      a severe cross-user leak. `no-store` keeps responses off disk
      and out of memory, `private` tells the proxy to pass through.

  Runs via `register_before_send/2` so it hits every response path
  (including the 401/429 emitted by `ApiAuth` and the 403 emitted by
  `require_scope!`).
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    register_before_send(conn, &apply_headers/1)
  end

  defp apply_headers(conn) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", "private, no-store")
  end
end
