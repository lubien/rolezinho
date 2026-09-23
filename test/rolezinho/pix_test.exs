defmodule Rolezinho.PixTest do
  use ExUnit.Case, async: true

  alias Rolezinho.Pix

  describe "detect/1" do
    test "detects a plain 11-digit phone key" do
      assert %{key: "+5591985609019", raw: "91985609019", display: display} =
               Pix.detect("Pix: 91985609019")

      assert display == "(91) 98560-9019"
    end

    test "detects when key has punctuation" do
      assert %{key: "+5591985609019"} = Pix.detect("PIX (91) 98560-9019")
    end

    test "keeps a key that already includes the country code" do
      assert %{key: "+5591985609019"} = Pix.detect("pix: +55 91 98560-9019")
    end

    test "returns nil when there is no pix key" do
      assert Pix.detect("Um texto qualquer sem chave.") == nil
      assert Pix.detect("") == nil
    end
  end

  describe "brcode/2" do
    test "produces a payload with the expected fields and a valid CRC" do
      brcode = Pix.brcode("+5591985609019", name: "Rolezinho", city: "Belem")

      assert brcode =~ "BR.GOV.BCB.PIX"
      assert brcode =~ "+5591985609019"
      # Ends with 4 hex CRC digits after the 6304 tag
      assert String.match?(brcode, ~r/6304[0-9A-F]{4}$/)
      # Currency and country markers
      assert brcode =~ "5303986"
      assert brcode =~ "5802BR"
    end

    test "embeds the amount after the currency when given, in reais with two decimals" do
      assert Pix.brcode("+5591985609019", amount_cents: 2200) =~ "5303986540522.005802BR"
      assert Pix.brcode("+5591985609019", amount_cents: 1550) =~ "540515.50"
      assert Pix.brcode("+5591985609019", amount_cents: 5) =~ "54040.05"
    end

    test "leaves the amount out when there is none" do
      for cents <- [nil, 0] do
        assert Pix.brcode("+5591985609019", amount_cents: cents) =~ "53039865802BR"
      end
    end
  end

  test "qr_svg/2 returns an SVG string" do
    svg = Pix.qr_svg("+5591985609019")
    assert is_binary(svg)
    assert svg =~ "<svg"
  end
end
