defmodule RolezinhoWeb.Markdown do
  @moduledoc """
  The one path that turns organizer-written text into HTML for `raw(...)`
  (`SECURITY.md`, section 1). Never call MDEx anywhere else.

  The pipeline, in order:

    1. WhatsApp markup becomes markdown (`Rolezinho.Event.WhatsMarkup`).
    2. MDEx parses it with `escape: true`: any raw HTML the organizer typed —
       inline or at the start of a line — is rendered as escaped text, and
       link URLs and titles are attribute-escaped.
    3. A link whose scheme isn't `http`, `https`, or `mailto` (`javascript:`,
       `data:`, …) is reduced to its text. Every remaining link gets
       `target="_blank"` and `rel="noopener noreferrer nofollow"`.
    4. The result goes through an allowlist sanitizer
       (`RolezinhoWeb.Markdown.Scrubber`), so no tag or attribute outside the
       allowlist reaches the page even if a rendering option changes.

  Bare URLs (`https://…`) become links on their own (GFM autolink).
  """

  alias Rolezinho.Event.WhatsMarkup
  alias RolezinhoWeb.Markdown.Scrubber

  @doc """
  Renders organizer text to sanitized HTML, ready for `raw/1`.

  ## Examples

      iex> RolezinhoWeb.Markdown.render("Veja https://example.com")
      "<p>Veja <a target=\\"_blank\\" rel=\\"noopener noreferrer nofollow\\" href=\\"https://example.com\\">https://example.com</a></p>"
  """
  @spec render(String.t()) :: String.t()
  def render(text) when is_binary(text) do
    text
    |> WhatsMarkup.to_markdown()
    |> MDEx.parse_document!(options())
    |> MDEx.traverse_and_update(&unwrap_unsafe_links/1)
    |> MDEx.to_html!(options())
    |> open_links_safely()
    |> Scrubber.sanitize()
  end

  defp options do
    [
      extension: [strikethrough: true, autolink: true],
      render: [hardbreaks: true, escape: true, unsafe: false]
    ]
  end

  # A link node can't be replaced by its children from its own callback, so the
  # unwrapping happens one level up, on whichever node holds the link.
  defp unwrap_unsafe_links(%{nodes: children} = node) when is_list(children) do
    %{node | nodes: Enum.flat_map(children, &keep_or_unwrap/1)}
  end

  defp unwrap_unsafe_links(node), do: node

  defp keep_or_unwrap(%MDEx.Link{url: url, nodes: children} = link) do
    if safe_scheme?(url), do: [link], else: children
  end

  defp keep_or_unwrap(node), do: [node]

  defp safe_scheme?(url), do: Regex.match?(~r/\A\s*(https?|mailto):/i, url)

  # With `escape: true` every `<` the organizer typed is already `&lt;`, so the
  # only literal `<a ` in the output is a link MDEx rendered itself.
  defp open_links_safely(html) do
    String.replace(html, "<a ", ~s(<a target="_blank" rel="noopener noreferrer nofollow" ))
  end
end
