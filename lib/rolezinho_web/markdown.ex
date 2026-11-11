defmodule RolezinhoWeb.Markdown do
  @moduledoc """
  The one path that turns organizer-written text into HTML for `raw(...)`
  (`SECURITY.md`, section 1). Never call Earmark anywhere else.

  The pipeline, in order:

    1. WhatsApp markup becomes markdown (`Rolezinho.Event.WhatsMarkup`).
    2. Double quotes become `&quot;`, so nothing Earmark interpolates into an
       attribute can close it (EEF-CVE-2026-48591).
    3. Earmark renders with `escape: true`. Links get `target="_blank"` and
       `rel="noopener noreferrer nofollow"`; a link whose scheme isn't `http`,
       `https`, or `mailto` (`javascript:`, `data:`, …) is reduced to its text.
    4. The result goes through an allowlist sanitizer
       (`RolezinhoWeb.Markdown.Scrubber`). `escape: true` only escapes HTML
       inside a paragraph — HTML at the start of a line is an HTML block and
       Earmark passes it through raw — so this last step is what guarantees
       no tag or attribute outside the allowlist reaches the page.

  Bare URLs (`https://…`) become links on their own (Earmark's `pure_links`).
  """

  alias Rolezinho.Event.WhatsMarkup
  alias RolezinhoWeb.Markdown.Scrubber

  @doc """
  Renders organizer text to sanitized HTML, ready for `raw/1`.

  ## Examples

      iex> RolezinhoWeb.Markdown.render("Veja https://example.com")
      "<p>\\nVeja <a href=\\"https://example.com\\" target=\\"_blank\\" rel=\\"noopener noreferrer nofollow\\">https://example.com</a></p>\\n"
  """
  @spec render(String.t()) :: String.t()
  def render(text) when is_binary(text) do
    text
    # WhatsApp markup first, so what the organizer typed becomes markdown
    # before anything else looks at it. Then the quote neutralizer, which has
    # to be the last thing between user text and Earmark — swapping these two
    # would let a converted span reintroduce a quote after it was made safe.
    |> WhatsMarkup.to_markdown()
    |> neutralize_attribute_injection()
    |> Earmark.as_html(
      breaks: true,
      escape: true,
      compact_output: false,
      registered_processors: [{"a", &link/1}]
    )
    |> case do
      {:ok, html, _warnings} -> html
      {:error, html, _warnings} -> html
    end
    |> Scrubber.sanitize()
  end

  # Earmark 1.4.x interpolates link/image URLs and titles into `href`/`src`/
  # `title` attributes without escaping double quotes, so
  # `[x](http://a/?b=c" onerror="alert(1))` closes the attribute and injects a
  # handler (EEF-CVE-2026-48591, no patched release — the package is retired).
  # Replacing the quote with its entity before parsing means nothing that
  # reaches an attribute can terminate it.
  defp neutralize_attribute_injection(text), do: String.replace(text, "\"", "&quot;")

  # Links open in a new tab without handing the opener or the referrer to the
  # destination, and carry no ranking weight. Anything but a web or mail link
  # keeps its text and loses the link.
  defp link({"a", attrs, children, meta}) do
    case List.keyfind(attrs, "href", 0) do
      {"href", href} ->
        if safe_scheme?(href) do
          attrs =
            attrs
            |> List.keystore("target", 0, {"target", "_blank"})
            |> List.keystore("rel", 0, {"rel", "noopener noreferrer nofollow"})

          {"a", attrs, children, meta}
        else
          {"span", [], children, meta}
        end

      nil ->
        {"span", [], children, meta}
    end
  end

  defp safe_scheme?(href), do: Regex.match?(~r/\A\s*(https?|mailto):/i, href)
end
