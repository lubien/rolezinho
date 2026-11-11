defmodule RolezinhoWeb.AccessCodeFieldTest do
  use ExUnit.Case, async: true

  doctest RolezinhoWeb.AccessCodeField

  alias RolezinhoWeb.AccessCodeField

  test "leaves params without the field untouched" do
    assert AccessCodeField.to_password(%{"title" => "x"}) == %{"title" => "x"}
  end
end
