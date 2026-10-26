defmodule RolezinhoWeb.Plugs.AgentDiscovery do
  @moduledoc """
  Adds an `X-Llm-Help: /agents.md` response header to every browser
  response, so an LLM or agent fetching any page can discover the
  agent-facing documentation without a separate request.

  Cheap (one header set), opt-out via `Plug.Conn.delete_resp_header/2`
  on surfaces where it would be noise (e.g. the API itself already
  tells agents what to do via `/api.md`).
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    put_resp_header(conn, "x-llm-help", "/agents.md")
  end
end
