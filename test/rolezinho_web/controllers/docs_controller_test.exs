defmodule RolezinhoWeb.DocsControllerTest do
  @moduledoc """
  Coverage for the agent-facing documentation served at
  `/api.md`, `/agents.md`, `/llms.txt`, and `/robots.txt`, plus
  the `X-Llm-Help` discovery header on every browser response.
  """
  use RolezinhoWeb.ConnCase, async: true

  describe "GET /api.md" do
    test "returns the API spec as markdown", %{conn: conn} do
      conn = get(conn, ~p"/api.md")

      assert conn.status == 200
      [ct] = get_resp_header(conn, "content-type")
      assert ct == "text/markdown; charset=utf-8"

      body = response(conn, 200)
      assert body =~ "# Rolezinho REST API"
      # Table of scopes.
      assert body =~ "events:read"
      assert body =~ "participants:write"
      # The `<host>` placeholder is substituted with the endpoint URL.
      refute body =~ "https://<host>"
    end
  end

  describe "GET /agents.md" do
    test "returns the agent overview as markdown", %{conn: conn} do
      conn = get(conn, ~p"/agents.md")

      assert conn.status == 200
      body = response(conn, 200)
      assert body =~ "# Rolezinho \u2014 agents and automation"
      # Points to the other three surfaces.
      assert body =~ "/api.md"
      assert body =~ "/atualizar.md"
      assert body =~ "/llms.txt"
    end
  end

  describe "GET /llms.txt" do
    test "returns a text/plain index following the llms.txt convention",
         %{conn: conn} do
      conn = get(conn, ~p"/llms.txt")

      assert conn.status == 200
      [ct] = get_resp_header(conn, "content-type")
      assert ct == "text/plain; charset=utf-8"

      body = response(conn, 200)
      # Top-line project heading.
      assert body =~ "# Rolezinho"
      # Links to each agent-facing doc.
      assert body =~ "/agents.md"
      assert body =~ "/api.md"
      assert body =~ "/atualizar.md"
    end
  end

  describe "GET /robots.txt" do
    test "allows crawling and highlights the agent-facing docs",
         %{conn: conn} do
      conn = get(conn, ~p"/robots.txt")

      assert conn.status == 200
      body = response(conn, 200)
      assert body =~ "User-agent: *"
      assert body =~ "Allow: /llms.txt"
      assert body =~ "Allow: /agents.md"
      assert body =~ "Allow: /api.md"
      assert body =~ "Allow: /atualizar.md"
    end
  end

  describe "agent-discovery header" do
    test "every browser response carries X-Llm-Help: /agents.md",
         %{conn: conn} do
      conn = get(conn, ~p"/")
      assert ["/agents.md"] = get_resp_header(conn, "x-llm-help")
    end

    test "docs responses carry it too (same browser pipeline)", %{conn: conn} do
      conn = get(conn, ~p"/api.md")
      assert ["/agents.md"] = get_resp_header(conn, "x-llm-help")
    end
  end
end
