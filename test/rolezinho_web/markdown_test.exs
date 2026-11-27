defmodule RolezinhoWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias RolezinhoWeb.Markdown

  defp links(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("a")
    |> Enum.map(fn a ->
      {LazyHTML.attribute(a, "href"), LazyHTML.attribute(a, "target"),
       LazyHTML.attribute(a, "rel")}
    end)
  end

  @safe_attrs {["_blank"], ["noopener noreferrer nofollow"]}

  describe "links" do
    test "a bare URL becomes a link that opens safely in a new tab" do
      assert [{["https://example.com/a"], target, rel}] =
               links(Markdown.render("Veja https://example.com/a aqui"))

      assert {target, rel} == @safe_attrs
    end

    test "markdown links and mailto get the same attributes" do
      assert [{["https://example.com"], t1, r1}] =
               links(Markdown.render("[site](https://example.com)"))

      assert [{["mailto:a@b.com"], t2, r2}] = links(Markdown.render("[m](mailto:a@b.com)"))
      assert {t1, r1} == @safe_attrs
      assert {t2, r2} == @safe_attrs
    end

    test "other schemes lose the link and keep the text" do
      for href <- [
            "javascript:alert(1)",
            " JavaScript:alert(1)",
            "data:text/html,oi",
            "vbscript:x"
          ] do
        html = Markdown.render("[clique](#{href})")

        assert links(html) == [], "expected no link for #{inspect(href)}"
        assert html =~ "clique"
      end
    end
  end

  describe "raw HTML" do
    test "HTML blocks at the start of a line never become markup" do
      for input <- [
            "<script>alert(1)</script>",
            "<iframe src=//evil.com></iframe>",
            "<form action=//evil><input name=senha></form>",
            "texto\n<div style=\"position:fixed;inset:0\">FAKE</div>",
            "<a href=\"javascript:alert(1)\">clique</a>",
            "<img src=x onerror=alert(1)>"
          ] do
        document = input |> Markdown.render() |> LazyHTML.from_fragment()

        assert Enum.empty?(LazyHTML.query(document, "script, iframe, form, input, div, img, a")),
               "leaked tag for #{inspect(input)}"

        assert Enum.empty?(LazyHTML.query(document, "[style], [onerror], [href], [src]")),
               "leaked attribute for #{inspect(input)}"
      end
    end

    test "attribute injection through a link URL or title stays inside the attribute" do
      for input <- [
            ~s{[x](http://a/?b=c" onerror="alert(1))},
            ~s{[x](https://a.com "t" onmouseover="alert(1)")}
          ] do
        document = input |> Markdown.render() |> LazyHTML.from_fragment()

        assert Enum.empty?(LazyHTML.query(document, "[onerror], [onmouseover]")),
               "injected attribute for #{inspect(input)}"
      end
    end

    test "inline HTML stays escaped text" do
      refute Markdown.render("oi <b>x</b> tchau") =~ "<b>"
    end
  end

  describe "formatting" do
    test "WhatsApp markup, lists, line breaks and paragraphs still render" do
      html = Markdown.render("*negrito* _itálico_ ~riscado~\n- um\n- dois\n\nLinha 1\nLinha 2")

      assert html =~ "<strong>negrito</strong>"
      assert html =~ "<em>itálico</em>"
      assert html =~ "<del>riscado</del>"
      assert html =~ "<li>"
      assert html =~ "<br"
    end
  end
end
