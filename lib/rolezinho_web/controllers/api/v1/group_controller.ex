defmodule RolezinhoWeb.Api.V1.GroupController do
  @moduledoc """
  Group resource for the REST API.

    * `GET /groups` — groups the caller owns.
    * `GET /groups/:slug` — one group they own.
    * `POST /groups` — create. Body: `{"name": "...", "slug": "...",
      "password": "...", "visibility": "public" | "hidden"}`.
    * `PATCH /groups/:slug` — update any of name, password,
      visibility. Slug is immutable (product rule).
    * `DELETE /groups/:slug` — delete.
  """
  use RolezinhoWeb, :controller

  import RolezinhoWeb.Api.Helpers

  alias Rolezinho.Group
  alias Rolezinho.Groups

  # ---------- Read ----------

  def index(conn, _params) do
    conn = require_scope!(conn, "groups:read")

    if conn.halted do
      conn
    else
      groups = Groups.list_owned_by(conn.assigns.current_user.id)
      json(conn, %{groups: Enum.map(groups, &group_summary/1)})
    end
  end

  def show(conn, %{"slug" => slug}) do
    conn = require_scope!(conn, "groups:read")

    if conn.halted do
      conn
    else
      with_owned_group(conn, slug, fn group ->
        json(conn, group_summary(group))
      end)
    end
  end

  # ---------- Write ----------

  def create(conn, params) do
    conn = require_scope!(conn, "groups:write")

    if conn.halted do
      conn
    else
      user_id = conn.assigns.current_user.id

      case Groups.create(normalize_create_params(params), created_by_user_id: user_id) do
        {:ok, group} ->
          conn |> put_status(:created) |> json(group_summary(group))

        {:error, %Ecto.Changeset{} = changeset} ->
          send_validation_error(conn, changeset)

        {:error, reason} ->
          send_validation_error(conn, inspect(reason))
      end
    end
  end

  def update(conn, %{"slug" => slug} = params) do
    conn = require_scope!(conn, "groups:write")

    if conn.halted do
      conn
    else
      with_owned_group(conn, slug, fn group ->
        case apply_group_updates(group, params) do
          {:ok, group} -> json(conn, group_summary(group))
          {:error, reason} -> group_update_error(conn, reason)
        end
      end)
    end
  end

  def delete(conn, %{"slug" => slug}) do
    conn = require_scope!(conn, "groups:write")

    if conn.halted do
      conn
    else
      with_owned_group(conn, slug, fn group ->
        case Groups.delete(group) do
          {:ok, _} -> send_resp(conn, 204, "")
          {:error, reason} -> send_validation_error(conn, inspect(reason))
        end
      end)
    end
  end

  # ---------- Shared ----------

  defp with_owned_group(conn, slug, fun) do
    user_id = conn.assigns.current_user.id

    case Groups.find(slug) do
      %Group{} = group ->
        if owned_by?(group, user_id),
          do: fun.(group),
          else: send_not_found(conn, "Group not found or not visible to this key.")

      nil ->
        send_not_found(conn, "Group not found or not visible to this key.")
    end
  end

  defp owned_by?(%Group{created_by_user_id: same}, same) when is_integer(same), do: true
  defp owned_by?(_, _), do: false

  defp normalize_create_params(params) do
    %{}
    |> Map.put("name", to_s(Map.get(params, "name")))
    |> Map.put("slug", to_s(Map.get(params, "slug")))
    |> maybe_put_string("password", params)
    |> maybe_put_string("visibility", params)
  end

  defp maybe_put_string(target, key, source) do
    case Map.get(source, key) do
      nil -> target
      value -> Map.put(target, key, to_s(value))
    end
  end

  defp apply_group_updates(group, params) do
    steps = [
      &maybe_update_name/2,
      &maybe_update_password/2,
      &maybe_update_visibility/2
    ]

    Enum.reduce_while(steps, {:ok, group}, fn step, {:ok, group} ->
      case step.(group, params) do
        {:ok, group} -> {:cont, {:ok, group}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp maybe_update_name(group, params) do
    case Map.get(params, "name") do
      nil -> {:ok, group}
      value -> Groups.update_name(group, to_s(value))
    end
  end

  defp maybe_update_password(group, params) do
    case Map.get(params, "password") do
      nil -> {:ok, group}
      value -> Groups.update_password(group, to_s(value))
    end
  end

  defp maybe_update_visibility(group, params) do
    case Map.get(params, "visibility") do
      nil -> {:ok, group}
      "public" -> Groups.update_visibility(group, :public)
      "hidden" -> Groups.update_visibility(group, :hidden)
      other -> {:error, "unknown visibility: #{inspect(other)}"}
    end
  end

  defp group_update_error(conn, %Ecto.Changeset{} = changeset),
    do: send_validation_error(conn, changeset)

  defp group_update_error(conn, reason) when is_binary(reason),
    do: send_validation_error(conn, reason)

  defp group_update_error(conn, reason),
    do: send_validation_error(conn, inspect(reason))

  defp to_s(nil), do: ""
  defp to_s(v) when is_binary(v), do: v
  defp to_s(v), do: to_string(v)
end
