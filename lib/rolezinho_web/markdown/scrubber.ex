defmodule RolezinhoWeb.Markdown.Scrubber do
  @moduledoc """
  The allowlist for rendered organizer markdown (see `RolezinhoWeb.Markdown`).

  Only the tags markdown itself produces survive, with no styling and no
  event attributes. Images are left out: the CSP (`img-src 'self' data:`)
  already blocks remote ones, and a relative `src` would let a description
  make every visitor's browser request a same-origin URL. Links keep `href` only for `http`, `https`, and `mailto`,
  plus the exact `target`/`rel` pair `RolezinhoWeb.Markdown` adds. Everything
  else — `<script>`, `<iframe>`, `<form>`, `<div style=…>` — is stripped,
  whatever Earmark let through.
  """

  use HtmlSanitizeEx, extend: :strip_tags

  allow_tag_with_uri_attributes("a", ["href"], ["http", "https", "mailto"])
  allow_tag_with_these_attributes("a", ["title"])
  allow_tag_with_this_attribute_values("a", "target", ["_blank"])
  allow_tag_with_this_attribute_values("a", "rel", ["noopener noreferrer nofollow"])

  allow_tag_with_these_attributes("p", [])
  allow_tag_with_these_attributes("br", [])
  allow_tag_with_these_attributes("strong", [])
  allow_tag_with_these_attributes("em", [])
  allow_tag_with_these_attributes("del", [])
  allow_tag_with_these_attributes("code", [])
  allow_tag_with_these_attributes("pre", [])
  allow_tag_with_these_attributes("blockquote", [])
  allow_tag_with_these_attributes("ul", [])
  allow_tag_with_these_attributes("ol", [])
  allow_tag_with_these_attributes("li", [])
  allow_tag_with_these_attributes("hr", [])
  allow_tag_with_these_attributes("h1", [])
  allow_tag_with_these_attributes("h2", [])
  allow_tag_with_these_attributes("h3", [])
  allow_tag_with_these_attributes("h4", [])
  allow_tag_with_these_attributes("h5", [])
  allow_tag_with_these_attributes("h6", [])
  allow_tag_with_these_attributes("span", [])
end
