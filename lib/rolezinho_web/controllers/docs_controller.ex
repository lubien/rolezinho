defmodule RolezinhoWeb.DocsController do
  @moduledoc """
  Serves the three agent-facing docs (`/api.md`, `/agents.md`,
  `/llms.txt`) and the `/robots.txt` index.

  Same pattern as `RolezinhoWeb.UpdateFromChatController`: files
  live in `priv/static/docs/` (plus `priv/static/llms.txt`), are
  embedded into the module at compile time via `@external_resource`
  so a fresh release never touches the filesystem, and are
  substituted with the endpoint's real host at request time so an
  agent reading the markdown sees working absolute URLs.
  """
  use RolezinhoWeb, :controller

  alias RolezinhoWeb.Endpoint

  @api_path Application.app_dir(:rolezinho, "priv/static/docs/api.md")
  @agents_path Application.app_dir(:rolezinho, "priv/static/docs/agents.md")
  @llms_path Application.app_dir(:rolezinho, "priv/static/llms.txt")

  @external_resource @api_path
  @external_resource @agents_path
  @external_resource @llms_path

  @api_template File.read!(@api_path)
  @agents_template File.read!(@agents_path)
  @llms_template File.read!(@llms_path)

  def api(conn, _params), do: send_markdown(conn, @api_template)
  def agents(conn, _params), do: send_markdown(conn, @agents_template)

  def llms(conn, _params) do
    body = String.replace(@llms_template, "https://<host>", public_url())

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, body)
  end

  defp send_markdown(conn, template) do
    body = String.replace(template, "https://<host>", public_url())

    conn
    |> put_resp_content_type("text/markdown")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, body)
  end

  defp public_url, do: Endpoint.url()
end
