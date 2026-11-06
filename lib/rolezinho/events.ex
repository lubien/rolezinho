defmodule Rolezinho.Events do
  @moduledoc """
  Context for managing rolezinhos, backed by Postgres.

  Every persisting function broadcasts on the `event:<slug>` PubSub topic so
  connected LiveViews stay in sync, plus a `events:home` topic for the home
  page listing.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Phoenix.PubSub
  alias Rolezinho.Event
  alias Rolezinho.Event.FormField
  alias Rolezinho.Event.Meta
  alias Rolezinho.Event.Parser
  alias Rolezinho.Event.Token
  alias Rolezinho.Pix
  alias Rolezinho.Repo

  @pubsub Rolezinho.PubSub

  @statuses [:active, :maybe, :payments_only, :done]

  @doc "PubSub topic for a specific slug."
  def topic(slug), do: "event:" <> slug

  @doc "Subscribes the caller to updates for a given slug."
  def subscribe(slug), do: PubSub.subscribe(@pubsub, topic(slug))

  @doc "Subscribes the caller to the home-page updates."
  def subscribe_home, do: PubSub.subscribe(@pubsub, "events:home")

  # ---------- Listing ----------

  @doc """
  Lists events shown on the public home page (active + payments_only).

  Events belonging to a group are excluded: the group represents them on the
  home page instead. See `Rolezinho.Groups.list_public/0` for the group
  listing that appears above these on the home screen.

  Ordered by when they happen, not by name: someone opening the home screen
  wants to know what is next, and alphabetical order puts tomorrow's event
  below one three weeks away. Events with no date sort last — they cannot be
  next if nobody has said when.
  """
  def list_open do
    # `hidden = false` is the second half of "public home" alongside
    # `status in open_statuses`. Before the hidden/status split these
    # were the same axis; they are orthogonal now, so both must hold.
    from(e in Event,
      where:
        e.status in ^Event.open_statuses() and
          not e.hidden and
          is_nil(e.group_id),
      order_by: [asc_nulls_last: e.starts_at, asc: e.title]
    )
    |> Repo.all()
  end

  @doc """
  The home listing: `list_open/0` plus the viewer's own events, deduped and
  ordered — public ones first, then the viewer's extras in date order.

  "Own" means created by `user_id`, joined by `user_id` (main or waiting
  list), or one of `device_slugs` — the slugs this browser holds a
  participant or organizer token for. Those slugs are only *candidates*: the
  caller still checks the token against the event (see
  `Rolezinho.Event.Membership`), since a stale token for a slug proves
  nothing.

  Own events include hidden and grouped ones; the group is preloaded so the
  caller can badge it and apply the group's password gate. `:done` events
  are left out: the home is about what is next, not an archive.
  """
  @spec list_home_for(integer() | nil, [String.t()]) :: [Event.t()]
  def list_home_for(user_id, device_slugs \\ [])

  def list_home_for(nil, []), do: list_open() |> Repo.preload(:group)

  def list_home_for(user_id, device_slugs) when is_list(device_slugs) do
    open = list_open()

    mine =
      from(e in Event,
        where: e.status != :done,
        where: ^own_condition(user_id, device_slugs),
        order_by: [asc_nulls_last: e.starts_at, asc: e.title]
      )
      |> Repo.all()

    open_ids = MapSet.new(open, & &1.id)
    extra_mine = Enum.reject(mine, &MapSet.member?(open_ids, &1.id))

    Repo.preload(open ++ extra_mine, :group)
  end

  @doc """
  Lists the events a signed-in user can bundle into a multi-share message:
  everything they created that isn't `:done`, hidden and grouped ones
  included — the owner picks what goes out. Ordered like the home page.

  `nil` in and you get `[]`.
  """
  @spec list_shareable_for(integer() | nil) :: [Event.t()]
  def list_shareable_for(nil), do: []

  def list_shareable_for(user_id) when is_integer(user_id) do
    from(e in Event,
      where: e.created_by_user_id == ^user_id and e.status != :done,
      order_by: [asc_nulls_last: e.starts_at, asc: e.title],
      preload: :group
    )
    |> Repo.all()
  end

  # `main_list` / `wait_list` are `{:array, :map}` — `jsonb[]` in Postgres.
  # `unnest()` turns the array into rows of jsonb, then `->>` reads the
  # user_id string from each attendee's map. Rows with a nil user_id compare
  # unequal, which is the intent (anonymous joins don't count as "joined by
  # user X"). Built with `dynamic/2` because Ecto refuses `== ^nil`.
  defp own_condition(nil, device_slugs), do: dynamic([e], e.slug in ^device_slugs)

  defp own_condition(user_id, device_slugs) do
    dynamic(
      [e],
      e.slug in ^device_slugs or e.created_by_user_id == ^user_id or
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) att WHERE (att->>'user_id')::int = ?)",
          e.main_list,
          ^user_id
        ) or
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) att WHERE (att->>'user_id')::int = ?)",
          e.wait_list,
          ^user_id
        )
    )
  end

  @doc "Lists strictly active events."
  def list_active, do: do_list(:active)

  @doc "Lists payments-only events."
  def list_payments_only, do: do_list(:payments_only)

  @doc "Lists tentative (\"averiguando resenha\") events."
  def list_maybe, do: do_list(:maybe)

  @doc "Lists hidden events (across all statuses)."
  def list_hidden do
    from(e in Event, where: e.hidden == true, order_by: [asc: e.title])
    |> Repo.all()
  end

  @doc "Lists done events."
  def list_done, do: do_list(:done)

  @doc """
  Every event the given user created, ordered by `updated_at desc`.

  Unlike `list_updatable_for/2` this includes every status (done,
  payments_only) and hidden events. Used by the REST API's
  `GET /events` listing when the key carries `events:read`.
  """
  @spec list_owned_by(integer()) :: [Event.t()]
  def list_owned_by(user_id) when is_integer(user_id) do
    Repo.all(
      from e in Event,
        where: e.created_by_user_id == ^user_id,
        order_by: [desc: e.updated_at, desc: e.id]
    )
  end

  @doc """
  Every event where the given user is a participant (on main or
  wait list), ordered by `updated_at desc`.

  Scoped by `user_id` on the attendee row, not by `participant_id`
  (which is per-device and not durable across sessions). So this
  only returns events a signed-in user joined — anonymous joins
  don't show up here, which is fine for the API's "what have I
  joined" story.
  """
  @spec list_participated_by(integer()) :: [Event.t()]
  def list_participated_by(user_id) when is_integer(user_id) do
    query =
      from e in Event,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM unnest(?) att WHERE (att->>'user_id')::int = ?)",
            e.main_list,
            ^user_id
          ) or
            fragment(
              "EXISTS (SELECT 1 FROM unnest(?) att WHERE (att->>'user_id')::int = ?)",
              e.wait_list,
              ^user_id
            ),
        order_by: [desc: e.updated_at, desc: e.id]

    Repo.all(query)
  end

  @doc """
  Lists events the given signed-in user can update via `/atualizar`:
  everything they created that's still accepting changes to its list
  (`:active` or `:maybe`; not `:done`, not `:payments_only`), ordered
  by most-recently-touched first so the picker's top row is almost
  always the one they meant.

  Admins get the same query without the creator constraint — same
  "still updatable" filter, but across every event, since the whole
  point of the admin role is being able to fix things for anyone.

  `nil` in and you get `[]` — anonymous visitors have nothing to
  offer, and the picker page shows a sign-in prompt instead.
  """
  @spec list_updatable_for(integer() | nil, keyword()) :: [Event.t()]
  def list_updatable_for(user_id, opts \\ [])

  def list_updatable_for(nil, _opts), do: []

  def list_updatable_for(user_id, opts) when is_integer(user_id) do
    admin? = Keyword.get(opts, :admin?, false)
    open_statuses = [:active, :maybe]

    base = from e in Event, where: e.status in ^open_statuses, order_by: [desc: e.updated_at]

    query =
      if admin?,
        do: base,
        else: from(e in base, where: e.created_by_user_id == ^user_id)

    Repo.all(query)
  end

  defp do_list(status) do
    from(e in Event, where: e.status == ^status, order_by: [asc: e.title])
    |> Repo.all()
  end

  # ---------- Fetching ----------

  @doc """
  Finds an event by slug. Returns nil if not found.

    * `visibility: :public` -> active + hidden (default: excludes :done)
    * `visibility: :any`    -> any status
    * `visibility: :active` -> only active
  """
  def find(slug, opts \\ []) when is_binary(slug) do
    visibility = Keyword.get(opts, :visibility, :any)

    statuses =
      case visibility do
        :public -> Event.public_statuses()
        :any -> @statuses
        :active -> [:active]
      end

    from(e in Event, where: e.slug == ^slug and e.status in ^statuses)
    |> Repo.one()
  end

  @doc """
  Finds the event a given organizer token administers.

  Returns `nil` for a blank token so that a browser sending no secret never
  resolves to an event.
  """
  @spec get_by_organizer_token(String.t() | nil) :: Event.t() | nil
  def get_by_organizer_token(token) when is_binary(token) and token != "" do
    Repo.get_by(Event, organizer_token: token)
  end

  def get_by_organizer_token(_), do: nil

  @doc "Returns true when a slug already exists in any status."
  def slug_taken?(slug) do
    from(e in Event, where: e.slug == ^slug, select: 1)
    |> Repo.exists?()
  end

  # ---------- Creation ----------

  @doc """
  Creates a new event from admin form params.

  Expected keys (strings): `title`, `slug`, `description`, `local`, `date`,
  `time`, `main_size`, `wait_size`.
  """
  def create(params, opts \\ []) when is_map(params) do
    with {:ok, attrs} <- validate_create_params(params) do
      # `group_id` and `created_by_user_id` are deliberately absent from
      # `params` and taken from `opts` instead: accepting either as input
      # would let anyone drop an event into any group by id, or hand
      # themselves ownership of anything by id. The controller resolves both
      # from server-held state before forwarding them here.
      group_id = Keyword.get(opts, :group_id)
      created_by_user_id = Keyword.get(opts, :created_by_user_id)

      changeset =
        %Event{}
        |> Event.changeset(build_attrs(attrs, initial_hidden?(opts, params)))
        # Set here rather than cast from params: accepting it as input would let
        # a visitor choose the secret that administers the event.
        |> Ecto.Changeset.put_change(:organizer_token, Token.generate_organizer())
        |> Ecto.Changeset.put_change(:group_id, group_id)
        |> Ecto.Changeset.put_change(:created_by_user_id, created_by_user_id)

      case Repo.insert(changeset) do
        {:ok, event} ->
          broadcast_home()
          {:ok, event}

        {:error, changeset} ->
          {:error, changeset_errors(changeset)}
      end
    end
  end

  defp validate_create_params(params) do
    title = params |> Map.get("title", "") |> to_string() |> String.trim()
    slug = params |> Map.get("slug", "") |> to_string() |> String.trim() |> String.downcase()
    description = params |> Map.get("description", "") |> to_string()
    meta = Meta.from_params(params)
    main_size_raw = params |> Map.get("main_size", "")
    wait_size_raw = params |> Map.get("wait_size", "3")
    password = params |> Map.get("password", "") |> to_string() |> String.trim()

    errors = %{}
    errors = if title == "", do: put_error(errors, :title, "obrigatório"), else: errors
    errors = validate_slug(errors, slug)

    {main_size, errors} =
      validate_size(errors, main_size_raw, :main_size, 1, 500, "número inteiro entre 1 e 500")

    {wait_size, errors} =
      validate_size(errors, wait_size_raw, :wait_size, 0, 100, "número inteiro entre 0 e 100")

    raw_pix_key = trimmed(params, "pix_key")
    raw_pix_type = parse_pix_type(params["pix_key_type"])

    {pix_key, pix_key_type, errors} =
      validate_pix_pair(errors, raw_pix_key, raw_pix_type)

    if errors == %{} do
      {:ok,
       %{
         title: title,
         slug: slug,
         description: description,
         meta: meta,
         main_size: main_size,
         wait_size: wait_size,
         password: password,
         category: trimmed(params, "category"),
         local: trimmed(params, "local"),
         starts_at: parse_datetime(params["starts_at"]) || combine_date_time(params),
         ends_at: parse_datetime(params["ends_at"]),
         split_method: parse_split_method(params["split_method"]),
         price_cents: parse_price(params["price"]),
         total_cents: parse_price(params["total"]),
         pix_key: pix_key,
         pix_key_type: pix_key_type
       }}
    else
      {:error, errors}
    end
  end

  # Accepts the type as either an atom or a string, and returns the atom or
  # `nil` for anything unrecognized. Prevents `String.to_existing_atom/1` on
  # untrusted input (which is the reason we don't just do that here).
  defp parse_pix_type(nil), do: nil
  defp parse_pix_type(type) when is_atom(type), do: if(type in Pix.types(), do: type)

  defp parse_pix_type(type) when is_binary(type) do
    trimmed = type |> String.trim() |> String.downcase()

    Enum.find(Pix.types(), fn atom -> Atom.to_string(atom) == trimmed end)
  end

  defp parse_pix_type(_), do: nil

  # Validates (pix_key, pix_key_type) as a pair:
  #
  #   * both nil               → fine, no Pix on this event,
  #   * key set, type nil      → error ("choose the key type"),
  #   * key nil, type set      → type silently reset to nil,
  #   * both set               → key must be canonicalizable under that type,
  #     otherwise a shape error on the key field.
  #
  # Returns `{normalized_key, normalized_type, errors}` where the key is the
  # trimmed raw value (persistence stores exactly what the organizer typed;
  # canonicalization happens at render time via `Pix.canonicalize/2`).
  defp validate_pix_pair(errors, nil, _type), do: {nil, nil, errors}

  defp validate_pix_pair(errors, key, nil) when is_binary(key) do
    {key, nil, put_error(errors, :pix_key_type, "escolha o tipo da chave")}
  end

  defp validate_pix_pair(errors, key, type) when is_binary(key) and is_atom(type) do
    case Pix.canonicalize(key, type) do
      {:ok, _canonical} ->
        {key, type, errors}

      :error ->
        {key, type, put_error(errors, :pix_key, "não parece uma chave #{Pix.type_label(type)}")}
    end
  end

  defp trimmed(params, key) do
    case params |> Map.get(key) |> to_string() |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  # The form asks for a date and a time separately, because that is how someone
  # thinks about it. Stored as one instant, since "Wednesday 7pm" cannot be
  # sorted or turned into a calendar entry.
  #
  # The pair is read as local time in Brasília (UTC-3, no DST), which is the
  # wall clock everyone in the group is reading.
  defp combine_date_time(params) do
    with date when is_binary(date) <- params["date"],
         {:ok, date} <- Date.from_iso8601(String.trim(date)),
         {:ok, time} <- parse_time(params["time"]),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(3 * 3600, :second)
    else
      _ -> nil
    end
  end

  # A date with no time means the whole day; midnight is the conventional way to
  # say that in a timestamp.
  defp parse_time(nil), do: {:ok, ~T[00:00:00]}

  defp parse_time(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, ~T[00:00:00]}
      trimmed -> Time.from_iso8601(trimmed <> ":00")
    end
  end

  defp parse_time(_), do: {:ok, ~T[00:00:00]}

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime(_), do: nil

  # People write an amount the way they say it: "15", "R$ 15", "15,00". All three
  # mean the same thing, and rejecting two of them would be pedantry.
  defp parse_price(value) when is_integer(value), do: value

  defp parse_price(value) when is_binary(value) do
    digits = String.replace(value, ~r/[^\d,.]/, "")

    case Regex.run(~r/^(\d+)(?:[.,](\d{1,2}))?$/, digits) do
      [_, reais] -> String.to_integer(reais) * 100
      [_, reais, cents] -> String.to_integer(reais) * 100 + pad_cents(cents)
      _ -> nil
    end
  end

  defp parse_price(_), do: nil

  # Known strings to known atoms; anything else falls back to the default
  # rather than building an atom from user input.
  defp parse_split_method(method)
       when method in [:total_split, :per_person, :per_seat, :settle_up],
       do: method

  defp parse_split_method("total_split"), do: :total_split
  defp parse_split_method("per_seat"), do: :per_seat
  defp parse_split_method("settle_up"), do: :settle_up
  defp parse_split_method(_), do: :per_person

  defp pad_cents(cents) do
    cents |> String.pad_trailing(2, "0") |> String.to_integer()
  end

  defp validate_slug(errors, ""), do: put_error(errors, :slug, "obrigatório")

  defp validate_slug(errors, slug) do
    cond do
      not Regex.match?(Event.slug_regex(), slug) ->
        put_error(errors, :slug, "use letras minúsculas, números e traços")

      slug_taken?(slug) ->
        put_error(errors, :slug, "já está em uso")

      true ->
        errors
    end
  end

  defp validate_size(errors, raw, field, min, max, message) do
    case parse_int(raw) do
      {:ok, n} when n >= min and n <= max -> {n, errors}
      _ -> {0, put_error(errors, field, message)}
    end
  end

  # The born-hidden default (ADR-0002) is only for the truly anonymous
  # case. Admin and signed-in users get a visible rolê — both carry
  # accountability, which is what the mitigation was for.
  #
  # After the hidden/status split (2026-09), status is always `:active`
  # on create; the anonymous-safe default lives on the `hidden` boolean
  # instead. Callers can override via the `"hidden"` param at the form
  # layer, which lets an authenticated creator publish an occult rolê
  # deliberately (form checkbox added in a separate commit).
  defp initial_hidden?(opts, params) do
    cond do
      # Explicit form param wins over the safety default.
      Map.has_key?(params, "hidden") ->
        Map.get(params, "hidden") in [true, "true", "on", "1"]

      Keyword.get(opts, :admin?, false) ->
        false

      not is_nil(Keyword.get(opts, :created_by_user_id)) ->
        false

      true ->
        true
    end
  end

  defp build_attrs(attrs, hidden) do
    empty_slots = for _ <- 1..attrs.main_size//1, do: %{name: "", paid: false}

    %{
      slug: attrs.slug,
      title: attrs.title,
      status: :active,
      hidden: hidden,
      header: Meta.build_header(attrs.meta, attrs.description),
      footer: "",
      main_capacity: attrs.main_size,
      wait_enabled: attrs.wait_size > 0,
      wait_intro: "Lista de reserva",
      main_list: empty_slots,
      wait_list: [],
      password: attrs.password,
      category: attrs.category,
      local: attrs.local,
      starts_at: attrs.starts_at,
      ends_at: attrs.ends_at,
      split_method: attrs.split_method,
      price_cents: attrs.price_cents,
      total_cents: attrs.total_cents,
      pix_key: attrs.pix_key,
      pix_key_type: attrs.pix_key_type
    }
  end

  defp parse_int(v) when is_integer(v), do: {:ok, v}

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_int(_), do: :error

  defp put_error(errors, key, message) do
    Map.update(errors, key, [message], &[message | &1])
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ---------- Persistence primitives ----------

  @doc """
  Persists an event struct that has been mutated in memory. Uses the passed
  struct as the original DB state, so callers must not mutate the same struct
  used to derive it.
  """
  @spec save(Event.t()) :: {:ok, Event.t()} | {:error, term()}
  def save(%Event{} = event) do
    original =
      case event.id do
        nil -> %Event{}
        id -> Repo.get!(Event, id)
      end

    original
    |> Event.changeset(Event.attrs_from_struct(event))
    |> Repo.update()
    |> case do
      {:ok, saved} ->
        broadcast(saved)
        broadcast_home()
        {:ok, saved}

      {:error, changeset} ->
        {:error, changeset_errors(changeset)}
    end
  end

  # ---------- Raw editor ----------

  @doc """
  Replaces the whole event (title/header/lists/footer) by parsing the raw
  markdown blob provided by the admin.
  """
  @spec save_raw(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, term()}
  def save_raw(%Event{} = event, raw_content) when is_binary(raw_content) do
    parsed = Parser.parse(raw_content)

    attrs =
      %{
        slug: event.slug,
        status: event.status,
        title: parsed.title,
        header: parsed.header,
        footer: parsed.footer,
        main_capacity: parsed.main_capacity,
        wait_enabled: parsed.wait_enabled,
        wait_intro: parsed.wait_intro,
        main_list: Enum.map(parsed.main_list, &Map.from_struct/1),
        wait_list: Enum.map(parsed.wait_list, &Map.from_struct/1)
      }

    event
    |> Event.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, saved} ->
        broadcast(saved)
        broadcast_home()
        {:ok, saved}

      {:error, changeset} ->
        {:error, changeset_errors(changeset)}
    end
  end

  # ---------- Status changes ----------

  @doc """
  Flips the `hidden` boolean on an event.

  Orthogonal to `set_status/2`: a rolê can be, say, `:payments_only` AND
  hidden. Same broadcast surface as any other event write, so the home
  listing refreshes on subscribed clients.
  """
  @spec set_hidden(Event.t(), boolean()) :: {:ok, Event.t()} | {:error, map()}
  def set_hidden(%Event{hidden: same} = event, same) when is_boolean(same), do: {:ok, event}

  def set_hidden(%Event{} = event, hidden?) when is_boolean(hidden?) do
    event
    |> Ecto.Changeset.change(hidden: hidden?)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        broadcast(updated)
        broadcast_home()
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset_errors(changeset)}
    end
  end

  @doc "Changes an event's status."
  def set_status(%Event{} = event, new_status) when new_status in @statuses do
    if new_status == event.status do
      {:ok, event}
    else
      event
      |> Ecto.Changeset.change(status: new_status)
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          broadcast(updated)
          broadcast_home()
          {:ok, updated}

        {:error, changeset} ->
          {:error, changeset_errors(changeset)}
      end
    end
  end

  @doc "Permanently deletes an event."
  def delete(%Event{} = event) do
    case Repo.delete(event) do
      {:ok, _} ->
        broadcast(event, :deleted)
        broadcast_home()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Clones an event.

  The clone's title is the source's, unchanged — in practice a repeat is
  "the same event, another day", so a suffix like " Clonado" reads as clutter
  the organizer has to remove before sharing. The slug still gets a
  `-clonado` tail (with a numeric disambiguator when needed) because the
  original's URL is already taken; that tail is dropped later, on the first
  date edit, by the retag logic in `RolezinhoWeb.EventEditLive`.

  Two fields are set here rather than copied from the source's struct,
  because both are mass-assignment-protected and therefore invisible to
  `Event.attrs_from_struct/1`:

    * `group_id` — always copied from the source. A repeat belongs to the
      same group as the original: this is what the group's page is for.
    * `created_by_user_id` — taken from `opts[:created_by_user_id]`. The
      copy is authored by whoever performs the clone, not by whoever
      authored the source, so the durable-organizer rule (ADR-0002) points
      at the person actually managing the repeat. Cloning is admin-only
      upstream today, so this is typically the admin's own account (or
      `nil` when the admin uses the password bypass without signing in).
  """
  @spec clone(Event.t(), keyword()) :: {:ok, Event.t()} | {:error, term()}
  def clone(%Event{} = source, opts \\ []) do
    clone_slug = unique_clone_slug(source.slug)
    created_by_user_id = Keyword.get(opts, :created_by_user_id)

    attrs =
      source
      |> Event.attrs_from_struct()
      |> Map.merge(%{
        slug: clone_slug,
        title: source.title,
        status: :active,
        # RN-52: a repeat copies the setup, not the people. Carrying the list
        # over would open next week's rolê with last week's names already
        # confirmed — and the payment checks with them.
        main_list: empty_slots(source.main_capacity),
        wait_list: []
      })

    changeset =
      %Event{}
      |> Event.changeset(attrs)
      # The copy is its own event, so it gets its own secret: sharing one would
      # let whoever organized the original administer the repeat, and the other
      # way round.
      |> Ecto.Changeset.put_change(:organizer_token, Token.generate_organizer())
      |> Ecto.Changeset.put_change(:group_id, source.group_id)
      |> Ecto.Changeset.put_change(:created_by_user_id, created_by_user_id)

    case Repo.insert(changeset) do
      {:ok, clone} ->
        broadcast_home()
        {:ok, clone}

      {:error, changeset} ->
        {:error, changeset_errors(changeset)}
    end
  end

  defp empty_slots(capacity) when is_integer(capacity) and capacity > 0 do
    for _ <- 1..capacity, do: %{name: "", paid: false}
  end

  defp empty_slots(_capacity), do: []

  defp unique_clone_slug(source_slug) do
    base = source_slug <> "-clonado"

    if slug_taken?(base) do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = base <> "-" <> Integer.to_string(n)
        if slug_taken?(candidate), do: nil, else: candidate
      end)
    else
      base
    end
  end

  # ---------- Slug rename ----------

  @doc """
  Renames an event's slug. Returns:

    * `{:ok, updated_event}` on success (including when unchanged),
    * `{:error, :invalid_slug}` when the format is invalid,
    * `{:error, :slug_taken}` when another event already uses the target slug,
    * `{:error, changeset_errors}` on other validation failures.
  """
  @spec rename_slug(Event.t(), String.t()) ::
          {:ok, Event.t()} | {:error, :invalid_slug | :slug_taken | map()}
  def rename_slug(%Event{} = event, new_slug) when is_binary(new_slug) do
    new_slug = new_slug |> String.trim() |> String.downcase()

    cond do
      new_slug == event.slug ->
        {:ok, event}

      not Regex.match?(Event.slug_regex(), new_slug) ->
        {:error, :invalid_slug}

      slug_taken?(new_slug) ->
        {:error, :slug_taken}

      true ->
        old_slug = event.slug

        Multi.new()
        |> Multi.update(:event, Ecto.Changeset.change(event, slug: new_slug))
        |> Repo.transaction()
        |> case do
          {:ok, %{event: updated}} ->
            PubSub.broadcast(@pubsub, topic(old_slug), {:moved, updated})
            broadcast(updated)
            broadcast_home()
            {:ok, updated}

          {:error, :event, changeset, _} ->
            case Keyword.get(changeset.errors, :slug) do
              {_msg, [{:constraint, :unique} | _]} -> {:error, :slug_taken}
              _ -> {:error, changeset_errors(changeset)}
            end
        end
    end
  end

  # ---------- Title & description ----------

  @doc """
  Updates the event's title and free-form description.

  The description is the free-form text a person writes to the group —
  everything that is not a structured field (location, date, time, price,
  Pix key, list, etc.). It is stored inside `header` alongside the meta
  lines, and this function preserves those meta lines: only the prose part
  is replaced.

  Params keys (strings):
    * `"title"` — non-empty, trimmed, capped at 80 characters.
    * `"description"` — free-form text, may be empty (which clears it).
  """
  @spec update_details(Event.t(), map()) :: {:ok, Event.t()} | {:error, map()}
  def update_details(%Event{} = event, params) when is_map(params) do
    title = params |> Map.get("title", "") |> to_string() |> String.trim()
    description = params |> Map.get("description", "") |> to_string()

    {meta, _old_description} = Meta.extract(event.header)
    new_header = Meta.build_header(meta, description)

    event
    |> Event.changeset(%{title: title, header: new_header})
    |> Repo.update()
    |> case do
      {:ok, saved} ->
        broadcast(saved)
        broadcast_home()
        {:ok, saved}

      {:error, changeset} ->
        {:error, changeset_errors(changeset)}
    end
  end

  @doc """
  Updates every free-text/date field of the event in one Ecto changeset.

  Bundles what used to be four separate context calls (`update_details`,
  `update_meta`, `update_payment`, `update_password`) so the admin edit
  screen can save the whole "details" card atomically — partial saves would
  leave the row half-changed if any of the intermediate updates failed.

  Slug rename is **not** part of this: it has redirect semantics and its own
  broadcast, and belongs to `rename_slug/2` (the edit screen still calls it
  first when the slug field changed).

  The `local` / `starts_at` / `ends_at` columns are kept in sync with the
  meta lines inside `header`. The role card and calendar surfaces read from
  the structured columns; the raw text output reads from the header. Both
  writes have to happen or the two views of the same event drift apart
  (event page shows "22/09 · 19h", group card still shows the old date).

  Params keys (strings), all optional:
    * `"title"` — trimmed, required to be non-empty via the changeset.
    * `"description"` — free-form text; empty clears it.
    * `"local"`, `"date"`, `"time"` — forwarded to `Meta.from_params/1` for
      the header, and to `local` / `starts_at` on the row.
    * `"category"` — trimmed; empty clears the field.
    * `"price"` — free-form (`"15"`, `"R$ 15"`, `"15,50"`); empty clears
      `price_cents`.
    * `"pix_key"` — any Pix key; empty clears the field.
    * `"password"` — empty clears; trimmed and stored plaintext by product
      decision (see `SECURITY.md` §3).
  """
  @spec update_full_details(Event.t(), map()) :: {:ok, Event.t()} | {:error, map()}
  def update_full_details(%Event{} = event, params) when is_map(params) do
    title = params |> Map.get("title", "") |> to_string() |> String.trim()
    description = params |> Map.get("description", "") |> to_string()
    meta = Meta.from_params(params)
    new_header = Meta.build_header(meta, description)

    raw_pix_key = trimmed(params, "pix_key")
    raw_pix_type = parse_pix_type(params["pix_key_type"])

    {pix_key, pix_key_type, errors} =
      validate_pix_pair(%{}, raw_pix_key, raw_pix_type)

    if errors == %{} do
      attrs = %{
        title: title,
        header: new_header,
        # Structured columns — same data as the meta lines, in a shape the
        # role card and calendar exports can read without parsing.
        local: trimmed(params, "local"),
        starts_at: combine_date_time(params),
        category: trimmed(params, "category"),
        password: params |> Map.get("password", "") |> to_string(),
        split_method: parse_split_method(Map.get(params, "split_method", event.split_method)),
        price_cents: parse_price(params["price"]),
        total_cents: parse_price(Map.get(params, "total", event.total_cents)),
        pix_key: pix_key,
        pix_key_type: pix_key_type
      }

      event
      |> Event.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, saved} ->
          broadcast(saved)
          broadcast_home()
          {:ok, saved}

        {:error, changeset} ->
          {:error, changeset_errors(changeset)}
      end
    else
      {:error, errors}
    end
  end

  # ---------- Meta ----------

  @doc """
  Updates the structured meta (local/data/horário) on an event. The free-form
  part of the header is preserved.
  """
  def update_meta(%Event{} = event, %Meta{} = new_meta) do
    {_current_meta, rest} = Meta.extract(event.header)
    new_header = Meta.build_header(new_meta, rest)

    event
    |> Ecto.Changeset.change(header: new_header)
    |> Repo.update()
    |> case do
      {:ok, saved} ->
        broadcast(saved)
        broadcast_home()
        {:ok, saved}

      {:error, changeset} ->
        {:error, changeset_errors(changeset)}
    end
  end

  def update_meta(%Event{} = event, params) when is_map(params) do
    update_meta(event, Meta.from_params(params))
  end

  # ---------- Password ----------

  @doc """
  Sets, changes or clears the event's password. An empty/whitespace value
  clears the password.
  """
  def update_password(%Event{} = event, password) do
    event
    |> Event.changeset(%{password: password})
    |> Repo.update()
    |> case do
      {:ok, saved} ->
        broadcast(saved)
        broadcast_home()
        {:ok, saved}

      {:error, changeset} ->
        {:error, changeset_errors(changeset)}
    end
  end

  # ---------- Payment (price + pix_key) ----------

  @doc """
  Updates the event's payment fields (`price_cents` and `pix_key`).

  Accepts a params map with string keys `"price"` and `"pix_key"`, matching
  what the create form (`EventNewLive`) accepts. Blank values clear the fields,
  which is how the organizer removes a Pix key or turns a paid event into a
  free one.

    * `"price"` — free-form (`"15"`, `"R$ 15"`, `"15,50"`). Nil/blank/invalid
      clears `price_cents`.
    * `"pix_key"` — any DICT-shaped key (phone, CPF, CNPJ, email, random).
      Trimmed; blank clears `pix_key`.
  """
  @spec update_payment(Event.t(), map()) :: {:ok, Event.t()} | {:error, map()}
  def update_payment(%Event{} = event, params) when is_map(params) do
    raw_pix_key = trimmed(params, "pix_key")
    raw_pix_type = parse_pix_type(params["pix_key_type"])

    {pix_key, pix_key_type, errors} =
      validate_pix_pair(%{}, raw_pix_key, raw_pix_type)

    if errors == %{} do
      attrs = %{
        split_method: parse_split_method(Map.get(params, "split_method", event.split_method)),
        price_cents: parse_price(params["price"]),
        total_cents: parse_price(Map.get(params, "total", event.total_cents)),
        pix_key: pix_key,
        pix_key_type: pix_key_type
      }

      event
      |> Event.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, saved} ->
          broadcast(saved)
          broadcast_home()
          {:ok, saved}

        {:error, changeset} ->
          {:error, changeset_errors(changeset)}
      end
    else
      {:error, errors}
    end
  end

  # ---------- Password (continued) ----------

  @doc """
  Constant-time password check against the event's stored value. Returns true
  when the event has no password (i.e. is open to everyone).
  """
  @spec check_password(Event.t(), String.t() | nil) :: boolean()
  def check_password(%Event{password: nil}, _submitted), do: true
  def check_password(%Event{password: ""}, _submitted), do: true

  def check_password(%Event{password: expected}, submitted) when is_binary(submitted) do
    Plug.Crypto.secure_compare(expected, submitted)
  end

  def check_password(%Event{}, _), do: false

  # ---------- List operations ----------

  def add_to_main(%Event{} = event, name, opts \\ []) do
    with :ok <- ensure_signups_open(event),
         {:ok, updated} <- Event.add_to_main(event, name, opts) do
      save(updated)
    end
  end

  def add_to_wait(%Event{} = event, name, opts \\ []) do
    with :ok <- ensure_signups_open(event),
         {:ok, updated} <- Event.add_to_wait(event, name, opts) do
      save(updated)
    end
  end

  @doc """
  The questions this event's join form asks (RN-61).

  Falls back to the default form, so an event that predates custom forms — or
  one nobody configured — still asks for a name.
  """
  @spec form_fields(Event.t()) :: [FormField.t()]
  def form_fields(%Event{form_fields: fields}), do: FormField.for_event(fields)

  @doc """
  Adds a question to the join form.

  The id is derived from the label and kept unique, since it becomes both a form
  field name and a key in the attendee's answers.
  """
  @spec add_form_field(Event.t(), map()) :: {:ok, Event.t()} | {:error, term()}
  def add_form_field(%Event{} = event, params) do
    fields = form_fields(event)
    label = params |> Map.get("label", "") |> to_string() |> String.trim()
    type = params |> Map.get("type", "text") |> to_string()

    cond do
      label == "" ->
        {:error, :empty_label}

      type not in FormField.types() ->
        {:error, :invalid_type}

      length(fields) >= max_form_fields() ->
        {:error, :too_many_fields}

      true ->
        field = %FormField{
          id: FormField.build_id(label, Enum.map(fields, & &1.id)),
          label: label,
          type: type,
          required: Map.get(params, "required") in [true, "true", "on"],
          locked: false
        }

        save(%{event | form_fields: fields ++ [field]})
    end
  end

  @doc """
  Removes a question from the join form.

  Locked fields stay: the name identifies the row, so a list without it would
  have nothing to display (RN-60).
  """
  @spec remove_form_field(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, term()}
  def remove_form_field(%Event{} = event, id) do
    fields = form_fields(event)

    case Enum.find(fields, &(&1.id == id)) do
      nil -> {:error, :not_found}
      %FormField{locked: true} -> {:error, :locked_field}
      _ -> save(%{event | form_fields: Enum.reject(fields, &(&1.id == id))})
    end
  end

  @doc """
  Renames an existing form field.

  Only the human-facing `:label` moves; the field's `:id` (the key under
  which every attendee's answer is stored on `attendee.values`) stays
  immutable, so historical rows keep resolving to the same field. Same
  reasoning as event slugs: renaming a stable identifier would silently
  orphan every row that ever answered.

  Locked fields (the built-in name) cannot be renamed — the label there is
  part of the product's vocabulary, not the organizer's.

  Returns `{:ok, event}` on success and `{:error, reason}` on:

    * `:empty_label` — blank or whitespace-only label,
    * `:label_too_long` — more than 40 chars (matches `FormField.changeset`),
    * `:not_found` — no field with that id on this event,
    * `:locked_field` — attempt to rename the name field.
  """
  @spec rename_form_field(Event.t(), String.t(), String.t()) ::
          {:ok, Event.t()} | {:error, term()}
  def rename_form_field(%Event{} = event, id, new_label) when is_binary(new_label) do
    fields = form_fields(event)
    trimmed = String.trim(new_label)

    cond do
      trimmed == "" ->
        {:error, :empty_label}

      String.length(trimmed) > 40 ->
        {:error, :label_too_long}

      true ->
        case Enum.find(fields, &(&1.id == id)) do
          nil ->
            {:error, :not_found}

          %FormField{locked: true} ->
            {:error, :locked_field}

          _ ->
            updated =
              Enum.map(fields, fn field ->
                if field.id == id, do: %{field | label: trimmed}, else: field
              end)

            save(%{event | form_fields: updated})
        end
    end
  end

  @doc """
  Flips whether a question must be answered.

  A locked field cannot become optional — a row with no name is not a row.
  """
  @spec toggle_form_field_required(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, term()}
  def toggle_form_field_required(%Event{} = event, id) do
    fields = form_fields(event)

    case Enum.find(fields, &(&1.id == id)) do
      nil ->
        {:error, :not_found}

      %FormField{locked: true} ->
        {:error, :locked_field}

      _ ->
        updated =
          Enum.map(fields, fn field ->
            if field.id == id, do: %{field | required: not field.required}, else: field
          end)

        save(%{event | form_fields: updated})
    end
  end

  # Past this, the form stops being a form and becomes a survey nobody finishes.
  defp max_form_fields, do: 8

  @doc """
  Adds someone plus their companions in one action (RN-04).

  Returns `{:ok, event, placed}` with how many landed in each list, so the
  caller can say what actually happened rather than assuming everyone got in.
  """
  @spec add_party(Event.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, Event.t(), map()} | {:error, term()}
  def add_party(%Event{} = event, name, size, opts \\ []) do
    with :ok <- ensure_signups_open(event),
         {:ok, updated, placed} <- Event.add_party(event, name, size, opts),
         {:ok, saved} <- save(updated) do
      {:ok, saved, placed}
    end
  end

  defp ensure_signups_open(%Event{} = event) do
    if Event.locked_signups?(event), do: {:error, :signups_locked}, else: :ok
  end

  @doc """
  Returns the `limit` most recently typed names by this signed-in user,
  canonicalized and deduplicated, in "most recent first" order.

  Powers the join-form autocomplete: someone who signs into every rolê
  and always brings the same friends should not have to type their names
  from scratch every time. "Names by this user" = every attendee row
  (main OR wait) whose `user_id` matches, across every event; that
  includes the user themselves and any guests they added on their party
  (guests inherit `user_id` at join time, see `Event.new_attendee/2`).

  Canonicalization collapses casing/whitespace variants to one entry —
  "Pedro costa" and "pedro Costa" both become "Pedro Costa" and count
  as one suggestion. See `Attendee.canonical_name/1`.

  Returns `[]` for `nil` (anonymous caller) so the callsite can pipe an
  optional user id in without branching.
  """
  @spec recent_names_for_user(integer() | nil, pos_integer()) :: [String.t()]
  def recent_names_for_user(user_id, limit \\ 25)

  def recent_names_for_user(nil, _limit), do: []

  def recent_names_for_user(user_id, limit) when is_integer(user_id) and limit > 0 do
    # Postgres path: unnest both attendee arrays together (`array_cat` on
    # jsonb[]) into rows of jsonb, then extract `name` and `joined_at`
    # for those matching the user id. Casts:
    #   * `user_id` field is stored as jsonb number — `->>` returns text,
    #     so we cast to int for the equality.
    #   * `joined_at` is an ISO 8601 string — cast to timestamp so we can
    #     ORDER BY it in the outer step.
    rows =
      from(e in Event,
        cross_join: att in fragment("unnest(array_cat(?, ?))", e.main_list, e.wait_list),
        where:
          fragment("(?)->>'user_id'", att) != "" and
            fragment("((?)->>'user_id')::int", att) == ^user_id and
            fragment("(?)->>'name'", att) != "",
        select: {
          fragment("(?)->>'name'", att),
          fragment("(?)->>'joined_at'", att)
        }
      )
      |> Repo.all()

    rows
    |> Enum.map(fn {raw_name, joined_at} ->
      {Event.Attendee.canonical_name(raw_name), joined_at}
    end)
    |> Enum.reject(fn {canonical, _} -> canonical == "" end)
    |> Enum.group_by(fn {canonical, _} -> canonical end)
    |> Enum.map(fn {canonical, tuples} ->
      # "Latest" per canonical name so the ordering reflects the most
      # recent time the person appeared, not the first.
      latest = tuples |> Enum.map(fn {_, joined_at} -> joined_at end) |> Enum.max()
      {canonical, latest}
    end)
    |> Enum.sort_by(fn {_canonical, joined_at} -> joined_at end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {canonical, _joined_at} -> canonical end)
  end

  @doc """
  Records what the main-list attendee at `index` spent, and where they want to
  be paid back, for "Dividir no final".

  Params (string keys, as the form sends them):

    * `"amount"` — what the visitor typed ("200", "R$ 32,50"); blank clears it
      to zero. Bounded so a typo (or a hostile POST) can't turn the plan into
      nonsense.
    * `"pix_key"` — optional; blank clears it. Stored as typed, but it has to
      have the shape of a Pix key (`Rolezinho.Pix.classify/1`). When the key
      is absent from the params, the stored one is kept.

  The caller checks who may write the row — the same rule as the paid check
  (`Policy.can_toggle_paid?/3`).
  """
  @spec set_contribution(Event.t(), pos_integer(), map()) ::
          {:ok, Event.t()} | {:error, :invalid_amount | :invalid_pix_key | map()}
  def set_contribution(%Event{} = event, index, params) when is_map(params) do
    current = Enum.at(event.main_list, index - 1)

    with {:ok, cents} <- parse_contribution(params["amount"]),
         {:ok, pix_key} <-
           parse_payout_pix(Map.get(params, "pix_key", current && current.pix_key)) do
      save(Event.set_contribution(event, index, cents, pix_key))
    end
  end

  defp parse_payout_pix(nil), do: {:ok, nil}

  defp parse_payout_pix(key) when is_binary(key), do: key |> String.trim() |> check_payout_pix()

  defp parse_payout_pix(_), do: {:error, :invalid_pix_key}

  defp check_payout_pix(""), do: {:ok, nil}

  defp check_payout_pix(key) do
    case {String.length(key) <= 100, Pix.classify(key)} do
      {true, {:ok, _type, _canonical}} -> {:ok, key}
      _ -> {:error, :invalid_pix_key}
    end
  end

  defp parse_contribution(amount) when amount in [nil, ""], do: {:ok, 0}

  defp parse_contribution(amount) when is_binary(amount) do
    max = max_contribution_cents()

    case parse_price(amount) do
      cents when is_integer(cents) and cents <= max -> {:ok, cents}
      _ -> {:error, :invalid_amount}
    end
  end

  defp parse_contribution(_), do: {:error, :invalid_amount}

  # R$ 100.000 — far above any rolê, low enough to keep the numbers sane.
  defp max_contribution_cents, do: 10_000_000

  def remove_main(%Event{} = event, index), do: save(Event.remove_main(event, index))
  def remove_wait(%Event{} = event, index), do: save(Event.remove_wait(event, index))
  def toggle_paid_main(%Event{} = event, index), do: save(Event.toggle_paid_main(event, index))
  def toggle_paid_wait(%Event{} = event, index), do: save(Event.toggle_paid_wait(event, index))
  def rename_main(%Event{} = event, index, name), do: save(Event.rename_main(event, index, name))
  def rename_wait(%Event{} = event, index, name), do: save(Event.rename_wait(event, index, name))

  @doc """
  Updates a main-list attendee's name and form answers in one shot.

  `params` is a map that may carry a `"name"` (string) and a `"values"`
  (map keyed by form-field id). Missing keys leave the current value in
  place: an owner fixing their shirt size never has to retype their name,
  and vice-versa.

  Values are sanitized the same way `JoinController` sanitizes joins —
  unknown/locked keys are dropped, strings are trimmed and capped at 200
  chars — so this path is not a way around the join gate.
  """
  @spec update_main(Event.t(), pos_integer(), map()) :: {:ok, Event.t()} | {:error, map()}
  def update_main(%Event{} = event, index, params) when is_map(params) do
    save(Event.update_main(event, index, sanitize_update_params(event, params)))
  end

  @doc """
  Same as `update_main/3`, for a wait-list row.
  """
  @spec update_wait(Event.t(), pos_integer(), map()) :: {:ok, Event.t()} | {:error, map()}
  def update_wait(%Event{} = event, index, params) when is_map(params) do
    save(Event.update_wait(event, index, sanitize_update_params(event, params)))
  end

  @doc """
  Applies a `/atualizar`-shaped bulk update to an event.

  `changes` is the structured form the LiveView hands us after the
  human has reviewed the LLM's proposal and confirmed. Shape:

      %{
        add_fields: [%{"label" => "Tamanho"}, ...],
        remove_field_ids: ["typo-field"],
        main: %{1 => row, 2 => row, ...},   # 1-based row index
        wait: %{1 => row, ...}
      }

  Row shape (all keys optional):

      %{
        "name"   => "Alice",    # empty string clears the slot
        "values" => %{"tamanho" => "M"},
        "paid"   => true | false
      }

  Update rules per row:

    * empty name — the slot is cleared (empty `%Attendee{}`).
    * name changed vs. current — the slot is **replaced** with a
      fresh attendee (no `participant_id`, no `user_id`,
      `joined_at = utc_now`). Sending a new name is treated as "a
      different person is here now", so we do not carry the old
      identity forward.
    * name unchanged (or the current slot was empty) — values and
      paid update in place, preserving `participant_id` / `user_id`
      when they were already there.

  When `changes[:main_capacity]` differs from the event's current
  capacity, the list is resized around the row updates: **grow first**
  (so a row keyed at a slot past the current end has somewhere to land),
  then **shrink after** (`Event.resize_main/2` clamps at the number of
  filled slots, so a shrink can only take effect if the row updates
  cleared the excess names first). This makes the two directions safe
  in the same transaction: the URL can send `capacity=8` alongside
  `names[8]=` / `names[9]=` to shrink from 10 down to 8 in one hop.

  Adds and removes on the event's form-field set run **before** the
  row updates, so a row that references a newly-added field lands on
  disk with that field already recognised.

  Returns `{:ok, event}` on success, `{:error, reason}` on the first
  failure (mirrors how `Events.add_form_field/2` and
  `Events.remove_form_field/2` fail today).
  """
  @spec apply_chat_update(Event.t(), map()) :: {:ok, Event.t()} | {:error, term()}
  def apply_chat_update(%Event{} = event, changes) when is_map(changes) do
    add = Map.get(changes, :add_fields, [])
    remove = Map.get(changes, :remove_field_ids, [])
    main = Map.get(changes, :main, %{})
    wait = Map.get(changes, :wait, %{})
    target_capacity = Map.get(changes, :main_capacity)

    with {:ok, event} <- add_fields(event, add),
         {:ok, event} <- remove_fields(event, remove) do
      # Grow-only pre-pass: if the target is larger than current, or
      # the row proposals name a slot past the end, expand first so
      # the row loop has real slots to iterate over.
      max_slot = main |> Map.keys() |> Enum.max(fn -> 0 end)
      grow_target = Enum.max([event.main_capacity, target_capacity || 0, max_slot])

      event = maybe_resize(event, grow_target)
      event = apply_row_proposals(event, main, wait)

      # Post-pass shrink: only fires when the target was set AND is
      # smaller than current capacity. `resize_main/2` clamps at the
      # filled count, so an ambitious "capacity=1" with 5 filled rows
      # lands at 5, not 1 — no one is silently dropped by a resize.
      event =
        if is_integer(target_capacity) and target_capacity < event.main_capacity do
          Event.resize_main(event, target_capacity)
        else
          event
        end

      save(event)
    end
  end

  defp maybe_resize(%Event{main_capacity: current} = event, target)
       when is_integer(target) and target > current,
       do: Event.resize_main(event, target)

  defp maybe_resize(event, _), do: event

  defp add_fields(event, []), do: {:ok, event}

  defp add_fields(event, [field | rest]) do
    case add_form_field(event, field) do
      {:ok, event} -> add_fields(event, rest)
      {:error, reason} -> {:error, {:add_field, field, reason}}
    end
  end

  defp remove_fields(event, []), do: {:ok, event}

  defp remove_fields(event, [id | rest]) do
    case remove_form_field(event, id) do
      # `:not_found` on a remove is not fatal — the field the human
      # marked "discard" may already have been absent (e.g. a stale
      # form submission after a concurrent add). Move on.
      {:ok, event} -> remove_fields(event, rest)
      {:error, :not_found} -> remove_fields(event, rest)
      {:error, reason} -> {:error, {:remove_field, id, reason}}
    end
  end

  # Applies every proposal to `event.main_list` / `event.wait_list`
  # in memory, so we only Repo-hit once at `save/1` below.
  defp apply_row_proposals(%Event{} = event, main, wait) do
    event
    |> apply_list_proposals(:main_list, main)
    |> apply_list_proposals(:wait_list, wait)
  end

  defp apply_list_proposals(event, _list_key, proposals) when map_size(proposals) == 0, do: event

  defp apply_list_proposals(%Event{} = event, list_key, proposals) do
    list = Map.fetch!(event, list_key)

    updated =
      list
      |> Enum.with_index(1)
      |> Enum.map(fn {attendee, index} ->
        case Map.get(proposals, index) do
          nil -> attendee
          proposal -> merge_proposal(attendee, proposal, event)
        end
      end)

    Map.put(event, list_key, updated)
  end

  # The per-row merge. Trusts sanitize_chat_row_values/2 to have
  # already filtered `"values"` to known field ids.
  defp merge_proposal(%Event.Attendee{} = attendee, proposal, %Event{} = event) do
    proposed_name =
      case Map.get(proposal, "name") do
        nil -> nil
        value when is_binary(value) -> String.trim(value)
      end

    cond do
      # Empty (or explicitly cleared) name — wipe the slot back to a
      # placeholder. Same shape `remove_main/2` leaves behind.
      proposed_name == "" ->
        %Event.Attendee{}

      # No name change (or the URL didn't touch the name field) —
      # update values/paid in place and preserve identity.
      is_nil(proposed_name) or
        same_name?(proposed_name, attendee.name) or
          String.trim(attendee.name) == "" ->
        attendee
        |> maybe_set_name(proposed_name)
        |> merge_values(proposal, event)
        |> merge_paid(proposal)

      # Name changed — the slot is a different person now, so drop
      # the old identity and start fresh. Values and paid come from
      # the proposal; if the proposal doesn't set them, they default
      # to "empty" / false (a fresh row).
      true ->
        %Event.Attendee{
          name: proposed_name,
          participant_id: nil,
          user_id: nil,
          joined_at: DateTime.utc_now() |> DateTime.truncate(:second),
          values: sanitize_chat_row_values(event, Map.get(proposal, "values", %{})),
          paid: Map.get(proposal, "paid", false) == true
        }
    end
  end

  defp maybe_set_name(attendee, nil), do: attendee

  defp maybe_set_name(%Event.Attendee{} = attendee, name) when is_binary(name),
    do: %{attendee | name: name}

  defp merge_values(%Event.Attendee{values: current} = attendee, proposal, event) do
    case Map.get(proposal, "values") do
      nil ->
        attendee

      map when is_map(map) ->
        cleaned = sanitize_chat_row_values(event, map)
        %{attendee | values: Map.merge(current || %{}, cleaned)}
    end
  end

  defp merge_paid(%Event.Attendee{} = attendee, proposal) do
    case Map.get(proposal, "paid") do
      nil -> attendee
      value when is_boolean(value) -> %{attendee | paid: value}
      _ -> attendee
    end
  end

  # Same allow-listing as `sanitize_answers/2` but skips the
  # "drop nils / trim" branch — chat proposals are already trimmed
  # by `ChatUpdate.parse/1`. Values that name an unknown field are
  # dropped: the LiveView should have surfaced them as "new field"
  # suggestions and either created the field or discarded the value
  # before calling us.
  defp sanitize_chat_row_values(%Event{} = event, values) when is_map(values) do
    allowed_ids =
      event
      |> form_fields()
      |> Enum.reject(& &1.locked)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    Enum.reduce(values, %{}, fn {key, value}, acc ->
      id = to_string(key)

      cond do
        not MapSet.member?(allowed_ids, id) -> acc
        not is_binary(value) -> acc
        true -> Map.put(acc, id, String.slice(value, 0, 200))
      end
    end)
  end

  defp sanitize_chat_row_values(_event, _), do: %{}

  # Same-name check that ignores case + surrounding whitespace, so an
  # LLM sending "joao" doesn't wipe a slot named "João " over case /
  # accent noise. Full-string equality on the *cleaned* form so
  # "Alice Silva" and "Alice" still count as different people.
  defp same_name?(a, b) do
    normalize_name_for_compare(a) == normalize_name_for_compare(b)
  end

  defp normalize_name_for_compare(nil), do: ""

  defp normalize_name_for_compare(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^a-z0-9\s]+/u, "")
    |> String.replace(~r/\s+/u, " ")
  end

  @doc """
  Sanitizes a raw params map coming from an update form into the internal
  shape `Event.update_main/3` and friends expect (`%{name:, values:}`).

  Only fields the event actually asks (non-locked) contribute to `:values`.
  Anything else in the map is ignored, so a hostile browser cannot invent
  keys nobody asked about — same rule as `JoinController.collect_answers/2`.
  Blank strings become nil for the name (falls back to "leave as is" at
  the schema layer) and drop the value entry entirely.
  """
  @spec sanitize_update_params(Event.t(), map()) :: %{
          optional(:name) => String.t() | nil,
          optional(:values) => map()
        }
  def sanitize_update_params(%Event{} = event, params) when is_map(params) do
    name = params |> Map.get("name") |> sanitize_name()

    # Only include `:values` when the caller actually sent them. Passing an
    # empty map otherwise would silently wipe the row's stored answers on a
    # name-only edit — the schema layer takes `:values` as a full replacement.
    values_key_present? = Map.has_key?(params, "values")

    values =
      if values_key_present?,
        do: sanitize_answers(event, Map.get(params, "values", %{})),
        else: nil

    %{}
    |> maybe_put(:name, name)
    |> maybe_put(:values, values)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # The name arrives from an unauthenticated form: trim it, and treat blank
  # as "no change" (the schema-level `clean_name` would coerce to "", which
  # would blank a valid row). Length is enforced by `Attendee.changeset/2`.
  defp sanitize_name(nil), do: nil

  defp sanitize_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      other -> other
    end
  end

  defp sanitize_name(_), do: nil

  @doc """
  Sanitizes a raw values map to the subset of keys this event asks for.

  Locked fields (the built-in `name`) are excluded — they live on the
  attendee row, not in `values`. Each accepted value is trimmed and capped
  at 200 chars, mirroring the join controller's sanitizer.
  """
  @spec sanitize_answers(Event.t(), map()) :: map()
  def sanitize_answers(%Event{} = event, values) when is_map(values) do
    allowed_ids =
      event
      |> form_fields()
      |> Enum.reject(& &1.locked)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    values
    |> Enum.reduce(%{}, fn {key, raw}, acc ->
      id = to_string(key)

      if MapSet.member?(allowed_ids, id) do
        trimmed = raw |> to_string() |> String.trim()

        cond do
          trimmed == "" -> acc
          true -> Map.put(acc, id, String.slice(trimmed, 0, 200))
        end
      else
        acc
      end
    end)
  end

  def sanitize_answers(%Event{}, _), do: %{}

  def promote(%Event{} = event, index) do
    with :ok <- ensure_signups_open(event),
         {:ok, updated} <- Event.promote(event, index) do
      save(updated)
    end
  end

  def resize_main(%Event{} = event, new_size), do: save(Event.resize_main(event, new_size))

  @doc """
  Resizes the main list and toggles the wait list, atomically.

  `wait_enabled?` mirrors the create form's convention: any non-empty wait
  size flips it on, a zero flips it off. The wait list has no runtime
  capacity in this project (see `PRODUCT.md`) — the flag is the only knob.
  Existing wait-list entries are preserved either way; disabling only stops
  new joins from queueing.
  """
  @spec resize_lists(Event.t(), integer(), boolean()) :: {:ok, Event.t()} | {:error, term()}
  def resize_lists(%Event{} = event, new_main_size, wait_enabled?)
      when is_integer(new_main_size) and is_boolean(wait_enabled?) do
    event
    |> Event.resize_main(new_main_size)
    |> Map.put(:wait_enabled, wait_enabled?)
    |> save()
  end

  # ---------- Group membership ----------

  @doc """
  Moves an event into a group (by group id) or out of one (nil).

  Admin-only upstream. A non-admin never reaches this: creating an event with
  a group is the only path they have to associate the two, and that path
  authorizes on the group's password unlock at request time (see
  `RolezinhoWeb.EventCreateController`).
  """
  @spec set_group(Event.t(), integer() | nil) :: {:ok, Event.t()} | {:error, term()}
  def set_group(%Event{group_id: same} = event, same), do: {:ok, event}

  def set_group(%Event{} = event, group_id) when is_integer(group_id) or is_nil(group_id) do
    event
    |> Event.put_group_id(group_id)
    |> Repo.update()
    |> case do
      {:ok, saved} ->
        broadcast(saved)
        broadcast_home()
        {:ok, saved}

      {:error, changeset} ->
        {:error, changeset_errors(changeset)}
    end
  end

  # ---------- Ownership ----------

  @doc """
  Moves the creator of an event to a specific user, or clears it.

  Admin-only upstream. This is the escape hatch for the grandfathered events
  that had `created_by_user_id = NULL` when ADR-0002 shipped: the admin can
  assign a real owner so the durable-organizer rule starts applying.
  """
  @spec set_created_by(Event.t(), integer() | nil) :: {:ok, Event.t()} | {:error, term()}
  def set_created_by(%Event{created_by_user_id: same} = event, same), do: {:ok, event}

  def set_created_by(%Event{} = event, user_id) when is_integer(user_id) or is_nil(user_id) do
    event
    |> Event.put_created_by_user_id(user_id)
    |> Repo.update()
    |> case do
      {:ok, saved} ->
        broadcast(saved)
        broadcast_home()
        {:ok, saved}

      {:error, changeset} ->
        {:error, changeset_errors(changeset)}
    end
  end

  # ---------- Broadcasts ----------

  defp broadcast(%Event{} = event, kind \\ :updated) do
    PubSub.broadcast(@pubsub, topic(event.slug), {kind, event})
  end

  defp broadcast_home do
    PubSub.broadcast(@pubsub, "events:home", :home_changed)
  end
end
