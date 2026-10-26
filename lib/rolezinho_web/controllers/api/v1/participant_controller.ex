defmodule RolezinhoWeb.Api.V1.ParticipantController do
  @moduledoc """
  Participant resource for the REST API.

    * `GET /events/:slug/participants` — read the attendee tree.
    * `POST /events/:slug/participants` — add one attendee. Body:
      `{"name": "...", "values": {...}, "paid": false, "list": "main" | "wait"}`.
      Defaults to `main`.
    * `PATCH /events/:slug/participants/:index` — edit name, values,
      or paid on one row. `?list=main|wait` picks which list.
    * `DELETE /events/:slug/participants/:index` — remove one row.
    * `POST /events/:slug/participants/:index/promote` — promote a
      wait-list row to the main list.
  """
  use RolezinhoWeb, :controller

  import RolezinhoWeb.Api.Helpers

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Events

  # ---------- Read ----------

  def index(conn, %{"slug" => slug}) do
    conn = require_scope!(conn, "participants:read")

    if conn.halted do
      conn
    else
      user_id = conn.assigns.current_user.id

      case Events.find(slug, visibility: :any) do
        %Event{} = event ->
          if owned_by?(event, user_id) or participant_on?(event, user_id) do
            json(conn, participant_payload(event))
          else
            send_not_found(conn, "Event not found or not visible to this key.")
          end

        nil ->
          send_not_found(conn, "Event not found or not visible to this key.")
      end
    end
  end

  # ---------- Write ----------

  def create(conn, %{"slug" => slug} = params) do
    conn = require_scope!(conn, "participants:write")

    if conn.halted do
      conn
    else
      with_owned_event(conn, slug, fn event ->
        name = params |> Map.get("name") |> to_s()
        values = params |> Map.get("values", %{}) |> ensure_map()

        case parse_list(params) do
          :main ->
            case Events.add_party(event, name, 1, values: values) do
              {:ok, event, _} ->
                conn |> put_status(:created) |> json(participant_payload(event))

              {:error, reason} ->
                send_validation_error(conn, inspect(reason))
            end

          :wait ->
            case Events.add_to_wait(event, name, values: values) do
              {:ok, event} ->
                conn |> put_status(:created) |> json(participant_payload(event))

              {:error, reason} ->
                send_validation_error(conn, inspect(reason))
            end
        end
      end)
    end
  end

  def update(conn, %{"slug" => slug, "index" => index} = params) do
    conn = require_scope!(conn, "participants:write")

    if conn.halted do
      conn
    else
      with_owned_event(conn, slug, fn event ->
        case parse_index(index) do
          {:ok, idx} ->
            event = maybe_set_paid(event, params, idx, parse_list(params))

            case apply_name_values(event, params, idx, parse_list(params)) do
              {:ok, event} -> json(conn, participant_payload(event))
              {:error, reason} -> send_validation_error(conn, inspect(reason))
            end

          :error ->
            send_validation_error(conn, "index must be a positive integer")
        end
      end)
    end
  end

  def delete(conn, %{"slug" => slug, "index" => index} = params) do
    conn = require_scope!(conn, "participants:write")

    if conn.halted do
      conn
    else
      with_owned_event(conn, slug, fn event ->
        case parse_index(index) do
          {:ok, idx} ->
            result =
              case parse_list(params) do
                :main -> Events.remove_main(event, idx)
                :wait -> Events.remove_wait(event, idx)
              end

            case result do
              {:ok, event} -> json(conn, participant_payload(event))
              {:error, reason} -> send_validation_error(conn, inspect(reason))
            end

          :error ->
            send_validation_error(conn, "index must be a positive integer")
        end
      end)
    end
  end

  def promote(conn, %{"slug" => slug, "index" => index}) do
    conn = require_scope!(conn, "participants:write")

    if conn.halted do
      conn
    else
      with_owned_event(conn, slug, fn event ->
        case parse_index(index) do
          {:ok, idx} ->
            case Events.promote(event, idx) do
              {:ok, event} -> json(conn, participant_payload(event))
              {:error, reason} -> send_validation_error(conn, inspect(reason))
            end

          :error ->
            send_validation_error(conn, "index must be a positive integer")
        end
      end)
    end
  end

  # ---------- Shared ----------

  defp with_owned_event(conn, slug, fun) do
    user_id = conn.assigns.current_user.id

    case Events.find(slug, visibility: :any) do
      %Event{} = event ->
        if owned_by?(event, user_id),
          do: fun.(event),
          else: send_not_found(conn, "Event not found or not writable by this key.")

      nil ->
        send_not_found(conn, "Event not found or not writable by this key.")
    end
  end

  defp owned_by?(%Event{created_by_user_id: same}, same) when is_integer(same), do: true
  defp owned_by?(_, _), do: false

  defp participant_on?(%Event{main_list: main, wait_list: wait}, user_id) do
    Enum.any?(main ++ wait, fn
      %Attendee{user_id: uid} when uid == user_id -> true
      _ -> false
    end)
  end

  defp participant_payload(%Event{} = event) do
    %{
      main_capacity: event.main_capacity,
      wait_enabled: event.wait_enabled,
      wait_intro: event.wait_intro,
      form_fields: Enum.map(event.form_fields, &form_field/1),
      main:
        event.main_list
        |> Enum.with_index(1)
        |> Enum.map(fn {row, i} -> attendee(row, i) end),
      wait:
        event.wait_list
        |> Enum.with_index(1)
        |> Enum.map(fn {row, i} -> attendee(row, i) end)
    }
  end

  defp parse_list(%{"list" => "wait"}), do: :wait
  defp parse_list(_), do: :main

  defp parse_index(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_index(_), do: :error

  # Paid is a toggle in the domain, not a set. Flip it only when the
  # caller explicitly sent `paid`, and only if the new value differs
  # from the current.
  defp maybe_set_paid(event, params, idx, list_kind) do
    case Map.get(params, "paid") do
      nil ->
        event

      value when is_boolean(value) ->
        row = row_at(event, idx, list_kind)

        if row && row.paid != value do
          toggle_paid(event, idx, list_kind)
        else
          event
        end

      _ ->
        event
    end
  end

  defp row_at(%Event{main_list: list}, idx, :main), do: Enum.at(list, idx - 1)
  defp row_at(%Event{wait_list: list}, idx, :wait), do: Enum.at(list, idx - 1)

  defp toggle_paid(event, idx, :main) do
    {:ok, event} = Events.toggle_paid_main(event, idx)
    event
  end

  defp toggle_paid(event, idx, :wait) do
    {:ok, event} = Events.toggle_paid_wait(event, idx)
    event
  end

  defp apply_name_values(event, params, idx, list_kind) do
    update_params = Map.take(params, ["name", "values"])

    if map_size(update_params) == 0 do
      {:ok, event}
    else
      case list_kind do
        :main -> Events.update_main(event, idx, update_params)
        :wait -> Events.update_wait(event, idx, update_params)
      end
    end
  end

  defp ensure_map(m) when is_map(m), do: m
  defp ensure_map(_), do: %{}

  defp to_s(nil), do: ""
  defp to_s(v) when is_binary(v), do: v
  defp to_s(v), do: to_string(v)
end
