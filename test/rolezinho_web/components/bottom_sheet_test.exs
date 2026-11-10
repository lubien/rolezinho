defmodule RolezinhoWeb.Components.UI.BottomSheetTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias RolezinhoWeb.Components.UI.BottomSheet

  defp render_sheet do
    assigns = %{}

    rendered_to_string(~H"""
    <BottomSheet.bottom_sheet id="demo" title="Demo">
      <p>Body</p>
      <:actions><button>Ok</button></:actions>
    </BottomSheet.bottom_sheet>
    """)
    |> LazyHTML.from_fragment()
  end

  test "has a close button that hides the sheet" do
    [close] = render_sheet() |> LazyHTML.query("#demo-close") |> Enum.to_list()

    assert LazyHTML.attribute(close, "aria-label") == ["Fechar"]
    assert [click] = LazyHTML.attribute(close, "phx-click")
    assert click =~ "#demo-panel"
  end

  test "caps the panel height and scrolls only the body" do
    html = render_sheet()

    assert [panel_class] = html |> LazyHTML.query("#demo-panel") |> LazyHTML.attribute("class")
    assert panel_class =~ "max-h-[85dvh]"
    assert html |> LazyHTML.query("#demo-panel > div.overflow-y-auto p") |> Enum.count() == 1
  end

  test "show/1 reveals the panel as a flex column" do
    %Phoenix.LiveView.JS{ops: ops} = BottomSheet.show("demo")

    assert Enum.any?(ops, fn
             ["show", %{to: "#demo-panel", display: "flex"}] -> true
             _ -> false
           end)
  end
end
