defmodule RolezinhoWeb.Api.Helpers do
  @moduledoc """
  Shared bits for every API controller:

    * Scope enforcement (`require_scope!/2`): halts the pipeline with
      `403` when the authenticated key doesn't carry the needed scope.
    * Consistent JSON error responses (`send_error/4`): same envelope
      the auth plug uses so a consumer sees one shape of error
      regardless of which layer rejected the request.
    * Serializers for the resources the API exposes (events, groups,
      participants, form fields). Kept as pure maps that `Jason.encode!/1`
      can digest; nothing clever, nothing fragile to add fields to.
  """

  import Plug.Conn

  alias Rolezinho.Accounts.ApiKey
  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.FormField
  alias Rolezinho.Group

  # ---------- Scope enforcement ----------

  @doc """
  Raises a `403` JSON response and halts the pipeline if the current
  key doesn't carry `scope`. Returns the (unchanged) conn when it
  does.

  Call at the top of each controller action.
  """
  @spec require_scope!(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def require_scope!(conn, scope) when is_binary(scope) do
    key = conn.assigns[:current_api_key]

    if is_struct(key, ApiKey) and ApiKey.has_scope?(key, scope) do
      conn
    else
      conn
      |> send_error(403, "forbidden", "This key is missing the `#{scope}` scope.")
      |> halt()
    end
  end

  # ---------- Error responses ----------

  @doc """
  Sends a standard-shape JSON error.

  Shape: `{"error": {"type": "...", "message": "...", "details": {...}}}`.
  `details` is omitted when it's nil or empty.
  """
  @spec send_error(Plug.Conn.t(), integer(), String.t(), String.t(), map() | nil) ::
          Plug.Conn.t()
  def send_error(conn, status, type, message, details \\ nil) do
    error = %{type: type, message: message}
    error = if details && details != %{}, do: Map.put(error, :details, details), else: error

    body = Jason.encode!(%{error: error})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  @doc "Convenience: 404 not found."
  def send_not_found(conn, message \\ "Not found.") do
    send_error(conn, 404, "not_found", message)
  end

  @doc "Convenience: 422 validation error with changeset field errors."
  def send_validation_error(conn, %Ecto.Changeset{} = changeset) do
    details = %{fields: changeset_errors(changeset)}
    send_error(conn, 422, "validation", "Validation failed.", details)
  end

  def send_validation_error(conn, message) when is_binary(message) do
    send_error(conn, 422, "validation", message)
  end

  defp changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end

  # ---------- Serializers ----------

  @doc """
  Compact event payload for list endpoints.

  `opts`:

    * `:role` — `"owner"` or `"participant"`, passed through so the
      caller can distinguish events they created from events they
      joined.
    * `:endpoint` — the `RolezinhoWeb.Endpoint` module, used to build
      the `url` field. Passed in so tests can swap it.
  """
  @spec event_summary(Event.t(), keyword()) :: map()
  def event_summary(%Event{} = event, opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, RolezinhoWeb.Endpoint)
    role = Keyword.get(opts, :role)

    %{
      slug: event.slug,
      title: event.title,
      status: Atom.to_string(event.status),
      hidden: event.hidden,
      category: event.category,
      local: event.local,
      starts_at: iso8601(event.starts_at),
      ends_at: iso8601(event.ends_at),
      main_capacity: event.main_capacity,
      wait_enabled: event.wait_enabled,
      filled_count: Enum.count(event.main_list, &(String.trim(&1.name) != "")),
      price_cents: event.price_cents,
      pix_key: event.pix_key,
      pix_key_type: event.pix_key_type && Atom.to_string(event.pix_key_type),
      group_slug: group_slug(event),
      role: role,
      created_at: iso8601(event.inserted_at),
      updated_at: iso8601(event.updated_at),
      url: endpoint.url() <> "/r/" <> event.slug
    }
  end

  @doc """
  Full event payload: summary + header, form fields, and both attendee
  lists. Used by `GET /events/:slug`.
  """
  @spec event_full(Event.t(), keyword()) :: map()
  def event_full(%Event{} = event, opts \\ []) do
    event
    |> event_summary(opts)
    |> Map.merge(%{
      header: event.header,
      footer: event.footer,
      wait_intro: event.wait_intro,
      form_fields: Enum.map(event.form_fields, &form_field/1),
      main: event.main_list |> Enum.with_index(1) |> Enum.map(&attendee_pair/1),
      wait: event.wait_list |> Enum.with_index(1) |> Enum.map(&attendee_pair/1)
    })
  end

  @doc "Serializes a `Group` for the API."
  @spec group_summary(Group.t(), keyword()) :: map()
  def group_summary(%Group{} = group, opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, RolezinhoWeb.Endpoint)

    %{
      slug: group.slug,
      name: group.name,
      visibility: Atom.to_string(group.visibility),
      has_password: Group.password_protected?(group),
      created_at: iso8601(group.inserted_at),
      updated_at: iso8601(group.updated_at),
      url: endpoint.url() <> "/g/" <> group.slug
    }
  end

  @doc "Serializes a `FormField` for the API."
  @spec form_field(FormField.t()) :: map()
  def form_field(%FormField{} = field) do
    %{
      id: field.id,
      label: field.label,
      type: field.type,
      required: field.required,
      locked: field.locked,
      placeholder: field.placeholder
    }
  end

  @doc """
  Serializes an attendee with its 1-based index.

  Empty slots serialize with `name: ""` so the caller can tell "vaga
  livre" from "gaps in the list" (gaps aren't a thing — the list is
  always `main_capacity` long).
  """
  @spec attendee(Attendee.t(), pos_integer()) :: map()
  def attendee(%Attendee{} = row, index) do
    %{
      index: index,
      name: row.name,
      paid: row.paid,
      values: row.values || %{},
      joined_at: iso8601(row.joined_at)
    }
  end

  defp attendee_pair({row, index}), do: attendee(row, index)

  defp group_slug(%Event{group: %Group{slug: slug}}), do: slug
  defp group_slug(_), do: nil

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
end
