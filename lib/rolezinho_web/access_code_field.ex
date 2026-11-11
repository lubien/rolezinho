defmodule RolezinhoWeb.AccessCodeField do
  @moduledoc """
  The form field for an event's or group's password, under a name password
  managers don't recognize.

  Bitwarden (and others) treat any input whose `name` or `id` contains
  "password" as a credential and offer to save it when the form submits —
  even a plain text input, even with `data-bwignore`. This password is a
  shared code for a group chat, not anyone's login, so the field goes out as
  `access_code` and is renamed back to `"password"` at the server boundary,
  before the params reach the contexts (`Events`, `Groups`).
  """

  @doc "The param key the forms use for the password field."
  @spec name() :: String.t()
  def name, do: "access_code"

  @doc """
  Renames `"access_code"` back to `"password"` in submitted params, leaving
  the map untouched when the field wasn't submitted.

  ## Examples

      iex> RolezinhoWeb.AccessCodeField.to_password(%{"access_code" => "fofoca", "title" => "x"})
      %{"password" => "fofoca", "title" => "x"}
  """
  @spec to_password(map()) :: map()
  def to_password(%{"access_code" => code} = params) do
    params |> Map.delete("access_code") |> Map.put("password", code)
  end

  def to_password(params) when is_map(params), do: params

  @doc """
  HTML attributes that tell password managers to leave the field alone. Not
  enough on their own (see the moduledoc) but they cover the managers that do
  honor them.
  """
  @spec ignore_attrs() :: keyword()
  def ignore_attrs do
    [
      autocomplete: "off",
      "data-1p-ignore": "true",
      "data-lpignore": "true",
      "data-bwignore": "true",
      "data-form-type": "other"
    ]
  end
end
