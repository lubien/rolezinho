defmodule RolezinhoWeb.Api.V1.EventController do
  @moduledoc """
  Event resource for the REST API.

    * `GET /events` — events the caller owns + events they joined.
    * `GET /events/:slug` — full payload for one event. Caller must
      own or be a participant on it.
    * `POST /events` — create a new event owned by the caller.
    * `PATCH /events/:slug` — partial update. Any subset of writable
      fields may appear; each is applied in sequence, stopping at
      the first failure.
    * `DELETE /events/:slug` — delete.
  """
  use RolezinhoWeb, :controller

  import RolezinhoWeb.Api.Helpers

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Events

  # ---------- Read ----------

  def index(conn, _params) do
    conn = require_scope!(conn, "events:read")

    if conn.halted do
      conn
    else
      user_id = conn.assigns.current_user.id

      owned = Events.list_owned_by(user_id)
      owned_ids = MapSet.new(owned, & &1.id)

      participated =
        user_id
        |> Events.list_participated_by()
        |> Enum.reject(&MapSet.member?(owned_ids, &1.id))

      events =
        Enum.map(owned, &event_summary(&1, role: "owner")) ++
          Enum.map(participated, &event_summary(&1, role: "participant"))

      json(conn, %{events: events})
    end
  end

  def show(conn, %{"slug" => slug}) do
    conn = require_scope!(conn, "events:read")

    if conn.halted do
      conn
    else
      with_event_for_read(conn, slug, fn event, role ->
        json(conn, event_full(event, role: role))
      end)
    end
  end

  # ---------- Write ----------

  def create(conn, params) do
    conn = require_scope!(conn, "events:write")

    if conn.halted do
      conn
    else
      user_id = conn.assigns.current_user.id

      case Events.create(normalize_create_params(params), created_by_user_id: user_id) do
        {:ok, event} ->
          conn
          |> put_status(:created)
          |> json(event_full(event, role: "owner"))

        {:error, %Ecto.Changeset{} = changeset} ->
          send_validation_error(conn, changeset)

        {:error, reason} when is_atom(reason) ->
          send_validation_error(conn, Atom.to_string(reason))

        {:error, reason} ->
          send_validation_error(conn, inspect(reason))
      end
    end
  end

  def update(conn, %{"slug" => slug} = params) do
    conn = require_scope!(conn, "events:write")

    if conn.halted do
      conn
    else
      with_owned_event(conn, slug, fn event ->
        case apply_event_updates(event, params) do
          {:ok, event} -> json(conn, event_full(event, role: "owner"))
          {:error, reason} -> event_update_error(conn, reason)
        end
      end)
    end
  end

  def delete(conn, %{"slug" => slug}) do
    conn = require_scope!(conn, "events:write")

    if conn.halted do
      conn
    else
      with_owned_event(conn, slug, fn event ->
        :ok = Events.delete(event)
        send_resp(conn, 204, "")
      end)
    end
  end

  # ---------- Shared ----------

  defp with_event_for_read(conn, slug, fun) do
    user_id = conn.assigns.current_user.id

    case Events.find(slug, visibility: :any) do
      %Event{} = event ->
        cond do
          owned_by?(event, user_id) -> fun.(event, "owner")
          participant_on?(event, user_id) -> fun.(event, "participant")
          true -> send_not_found(conn, "Event not found or not visible to this key.")
        end

      nil ->
        send_not_found(conn, "Event not found or not visible to this key.")
    end
  end

  defp with_owned_event(conn, slug, fun) do
    user_id = conn.assigns.current_user.id

    case Events.find(slug, visibility: :any) do
      %Event{} = event ->
        if owned_by?(event, user_id),
          do: fun.(event),
          # Return 404 even to a participant trying to mutate — don't
          # reveal that the event exists via a 403, which would say
          # "yes, this slug is real".
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

  # Translates the API's JSON into the shape `Events.create/2` wants.
  # Pass-through for most keys; the main_size/wait_size pair falls
  # back to sane defaults so a minimal POST ({"title": "x", "slug": "y"})
  # succeeds.
  defp normalize_create_params(params) do
    %{}
    |> Map.put("title", to_s(Map.get(params, "title")))
    |> Map.put("slug", to_s(Map.get(params, "slug")))
    |> Map.put("description", to_s(Map.get(params, "description", "")))
    |> Map.put("local", to_s(Map.get(params, "local", "")))
    |> Map.put("date", to_s(Map.get(params, "date", "")))
    |> Map.put("time", to_s(Map.get(params, "time", "")))
    |> Map.put("category", to_s(Map.get(params, "category", "")))
    |> Map.put("main_size", to_s(Map.get(params, "main_size", "10")))
    |> Map.put("wait_size", to_s(Map.get(params, "wait_size", "0")))
    |> maybe_put_string("password", params)
    |> maybe_put_string("pix_key", params)
    |> maybe_put_string("pix_key_type", params)
    |> maybe_put_string("price_cents", params)
    |> maybe_put_hidden(params)
  end

  defp maybe_put_string(target, key, source) do
    case Map.get(source, key) do
      nil -> target
      value -> Map.put(target, key, to_s(value))
    end
  end

  defp maybe_put_hidden(target, params) do
    case Map.get(params, "hidden") do
      nil -> target
      true -> Map.put(target, "hidden", "true")
      false -> Map.put(target, "hidden", "false")
      other -> Map.put(target, "hidden", to_s(other))
    end
  end

  defp to_s(nil), do: ""
  defp to_s(v) when is_binary(v), do: v
  defp to_s(v), do: to_string(v)

  # Walks the PATCH params and applies each known update in sequence.
  # Order matters only for cross-field consistency (e.g. you can resize
  # before mutating rows); each step short-circuits on error.
  defp apply_event_updates(event, params) do
    steps = [
      &maybe_update_details/2,
      &maybe_update_meta/2,
      &maybe_update_payment/2,
      &maybe_update_password/2,
      &maybe_rename_slug/2,
      &maybe_set_status/2,
      &maybe_set_hidden/2,
      &maybe_resize/2
    ]

    Enum.reduce_while(steps, {:ok, event}, fn step, {:ok, event} ->
      case step.(event, params) do
        {:ok, event} -> {:cont, {:ok, event}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp maybe_update_details(event, params) do
    if has_any?(params, ["title", "description", "local", "category"]) do
      # `update_full_details/2` covers title/description/local/date/
      # time/category/price/pix in one shot. Only the ones present in
      # params are touched; the context handles merging.
      merged = Map.merge(details_defaults(event), string_subset(params))
      Events.update_full_details(event, merged)
    else
      {:ok, event}
    end
  end

  defp maybe_update_meta(event, params) do
    if has_any?(params, ["date", "time", "local"]) do
      Events.update_meta(event, string_subset(params))
    else
      {:ok, event}
    end
  end

  defp maybe_update_payment(event, params) do
    if has_any?(params, ["pix_key", "pix_key_type", "price_cents"]) do
      Events.update_payment(event, string_subset(params))
    else
      {:ok, event}
    end
  end

  defp maybe_update_password(event, params) do
    case Map.get(params, "password") do
      nil -> {:ok, event}
      value -> Events.update_password(event, to_s(value))
    end
  end

  defp maybe_rename_slug(event, params) do
    case Map.get(params, "slug") do
      nil -> {:ok, event}
      value -> Events.rename_slug(event, to_s(value))
    end
  end

  defp maybe_set_status(event, params) do
    case Map.get(params, "status") do
      nil ->
        {:ok, event}

      status_str when is_binary(status_str) ->
        case parse_status(status_str) do
          {:ok, status} -> Events.set_status(event, status)
          :error -> {:error, "unknown status: #{status_str}"}
        end
    end
  end

  defp maybe_set_hidden(event, params) do
    case Map.get(params, "hidden") do
      nil -> {:ok, event}
      value when is_boolean(value) -> Events.set_hidden(event, value)
      "true" -> Events.set_hidden(event, true)
      "false" -> Events.set_hidden(event, false)
      _ -> {:error, "hidden must be a boolean"}
    end
  end

  defp maybe_resize(event, params) do
    case Map.get(params, "main_capacity") do
      nil ->
        {:ok, event}

      value when is_integer(value) and value > 0 ->
        Events.resize_main(event, value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n > 0 -> Events.resize_main(event, n)
          _ -> {:error, "main_capacity must be a positive integer"}
        end

      _ ->
        {:error, "main_capacity must be a positive integer"}
    end
  end

  defp has_any?(params, keys), do: Enum.any?(keys, &Map.has_key?(params, &1))

  defp string_subset(params) do
    for {k, v} <- params,
        is_binary(k) and (is_binary(v) or is_integer(v)),
        into: %{},
        do: {k, to_s(v)}
  end

  defp details_defaults(event) do
    %{
      "title" => event.title,
      "description" => extract_description(event)
    }
  end

  defp extract_description(%Event{header: header}) do
    {_meta, rest} = Rolezinho.Event.Meta.extract(header || "")
    rest
  end

  defp parse_status("active"), do: {:ok, :active}
  defp parse_status("maybe"), do: {:ok, :maybe}
  defp parse_status("payments_only"), do: {:ok, :payments_only}
  defp parse_status("done"), do: {:ok, :done}
  defp parse_status(_), do: :error

  defp event_update_error(conn, %Ecto.Changeset{} = changeset),
    do: send_validation_error(conn, changeset)

  defp event_update_error(conn, reason) when is_atom(reason),
    do: send_validation_error(conn, Atom.to_string(reason))

  defp event_update_error(conn, reason) when is_binary(reason),
    do: send_validation_error(conn, reason)

  defp event_update_error(conn, reason),
    do: send_validation_error(conn, inspect(reason))
end
