defmodule Rolezinho.Event do
  @moduledoc """
  Represents a rolezinho (event), persisted as a row in the `events` table.

  The struct also provides pure functions to render/share the event as text
  and to manipulate the attendee lists. All mutation functions return a new
  `%Event{}` struct without touching the database — the `Rolezinho.Events`
  context is what persists changes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Rolezinho.Event
  alias Rolezinho.Event.Attendee
  alias Rolezinho.Event.Cash
  alias Rolezinho.Event.FormField
  alias Rolezinho.Event.Settlement

  # `:maybe` ("averiguando resenha") is the tentative state: the event
  # might happen, depending on how many people opt in — signup is open,
  # the row appears on the public home, and its slug is reachable to
  # anyone. Cancellation is a separate decision (moving to `:done`);
  # `:maybe` is only a visual signal that going is not guaranteed yet.
  #
  # "Occult" (hidden from the public home) used to be part of this enum
  # as `:hidden`, but was split into its own boolean column so an event
  # can be, say, `payments_only` AND hidden at the same time — states
  # that were mutually exclusive under the old encoding. See
  # `20260922173451_split_hidden_from_status.exs`.
  @statuses [:active, :maybe, :payments_only, :done]

  # Statuses that appear on the public home page (still subject to the
  # `hidden` flag applied at the query layer in `Rolezinho.Events`).
  @open_statuses [:active, :maybe, :payments_only]
  @split_methods [:total_split, :per_person, :per_seat, :settle_up]

  # Statuses reachable by direct slug for anonymous visitors. Hidden events
  # remain reachable by slug — that's the whole point of being unlisted-
  # but-linkable — so this enum has nothing more to say about it.
  @public_statuses [:active, :maybe, :payments_only]

  @slug_regex ~r/^[a-z0-9](?:[a-z0-9-]{0,60}[a-z0-9])?$/

  schema "events" do
    field :slug, :string
    field :title, :string, default: ""
    field :status, Ecto.Enum, values: @statuses, default: :active

    # Whether this rolê is hidden from the public home (still reachable by
    # direct slug). Orthogonal to `:status` after the split — see the
    # module doc block. `nil` never appears at the DB level (NOT NULL,
    # default false), so we can assume boolean everywhere.
    field :hidden, :boolean, default: false
    field :header, :string, default: ""
    field :footer, :string, default: ""
    field :main_capacity, :integer, default: 0
    field :wait_enabled, :boolean, default: false
    field :wait_intro, :string, default: "Lista de reserva"
    field :password, :string

    # Structured replacements for what used to be parsed out of the markdown
    # header. `header`/`footer` above are on their way out, once the v2 screens
    # stop rendering them.
    field :category, :string
    field :local, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    # How the cost is split. `price_cents` is the per-seat price for
    # `:per_person` / `:per_seat`; `total_cents` is the whole bill for
    # `:total_split`; `:settle_up` uses neither — each attendee records what
    # they spent (`Attendee.contributed_cents`). See `Rolezinho.Event.Cash`.
    field :split_method, Ecto.Enum, values: @split_methods, default: :per_person
    field :price_cents, :integer
    field :total_cents, :integer
    field :pix_key, :string

    # Which of the five DICT key types the `pix_key` above is. The organizer
    # chooses this explicitly on the form, so an 11-digit number that could
    # be either a mobile phone or a CPF is not guessed. Nullable for events
    # created before the split — the runtime falls back to `Pix.classify/1`
    # for those and asks the organizer to pick on the next edit.
    field :pix_key_type, Ecto.Enum, values: [:phone, :cpf, :cnpj, :email, :random]

    # The organizer's secret for this event: whoever holds it administers this
    # event and no other.
    field :organizer_token, :string

    # Optional group this event belongs to. When set, the event is not listed
    # on the public home page (its group is) and, when the group has a
    # password, the event inherits the group's gate on its own page.
    belongs_to :group, Rolezinho.Group

    # Optional signed-in creator (ADR-0002). NULL for events created before
    # accounts existed and for events created via the admin bypass without a
    # user session. Grants organizer rights via `Rolezinho.Event.Policy`.
    belongs_to :created_by_user, Rolezinho.Accounts.User

    embeds_many :main_list, Attendee, on_replace: :delete
    embeds_many :wait_list, Attendee, on_replace: :delete

    # What the join form asks. Left nil until the organizer configures it, so
    # `FormField.for_event/1` can tell "never set up" from "asks nothing".
    embeds_many :form_fields, FormField, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @type status :: :active | :maybe | :payments_only | :done
  @type split_method :: :total_split | :per_person | :per_seat | :settle_up

  @type t :: %__MODULE__{
          id: integer() | nil,
          slug: String.t() | nil,
          status: status(),
          hidden: boolean(),
          title: String.t(),
          header: String.t(),
          main_capacity: non_neg_integer(),
          main_list: [Attendee.t()],
          wait_enabled: boolean(),
          wait_intro: String.t(),
          wait_list: [Attendee.t()],
          footer: String.t(),
          password: String.t() | nil,
          category: String.t() | nil,
          local: String.t() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          split_method: split_method(),
          price_cents: non_neg_integer() | nil,
          total_cents: non_neg_integer() | nil,
          pix_key: String.t() | nil,
          pix_key_type: :phone | :cpf | :cnpj | :email | :random | nil,
          organizer_token: String.t() | nil,
          group_id: integer() | nil,
          created_by_user_id: integer() | nil,
          form_fields: [FormField.t()]
        }

  @doc """
  Full changeset used by the `Rolezinho.Events` context to persist events.
  Callers pass a plain map of attributes; embeds are cast recursively.
  """
  def changeset(%Event{} = event, attrs) do
    event
    |> cast(attrs, [
      :slug,
      :title,
      :status,
      :hidden,
      :header,
      :footer,
      :main_capacity,
      :wait_enabled,
      :wait_intro,
      :password,
      :category,
      :local,
      :starts_at,
      :ends_at,
      :split_method,
      :price_cents,
      :total_cents,
      :pix_key,
      :pix_key_type
    ])
    |> update_change(:password, &normalize_password/1)
    |> cast_embed(:main_list, with: &Attendee.changeset/2)
    |> cast_embed(:wait_list, with: &Attendee.changeset/2)
    |> cast_embed(:form_fields, with: &FormField.changeset/2)
    |> validate_required([:slug, :title, :status])
    |> update_change(:slug, &String.downcase(String.trim(&1 || "")))
    |> validate_format(:slug, @slug_regex, message: "use letras minúsculas, números e traços")
    |> validate_number(:main_capacity, greater_than_or_equal_to: 0)
    # Upper bounds only: anonymous writes make an unbounded column a way to fill
    # the page, but a minimum here would reject events that already exist. The
    # 3-character floor the spec asks for belongs to the create form, which is
    # the only place a title is authored from scratch.
    |> validate_length(:title, max: 80)
    |> validate_length(:local, max: 200)
    |> validate_length(:category, max: 40)
    |> validate_length(:pix_key, max: 100)
    |> validate_number(:price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
    |> validate_ends_after_starts()
    |> unique_constraint(:slug, message: "já está em uso")
  end

  # `organizer_token` is deliberately absent from the cast above: it is what
  # authorizes administering this event, so accepting it from params would let a
  # visitor hand themselves the secret. It is set once, at creation, by the
  # context.
  @doc false
  def put_organizer_token(%Event{} = event, token) when is_binary(token) do
    change(event, organizer_token: token)
  end

  # `group_id` is also kept out of `cast` for mass-assignment reasons: a form
  # POST could otherwise stuff an event into any group by id. The Events
  # context is what sets it, either at creation (with an authorization check
  # against the group) or when an admin moves an event between groups.
  @doc false
  def put_group_id(%Event{} = event, nil), do: change(event, group_id: nil)
  def put_group_id(%Event{} = event, id) when is_integer(id), do: change(event, group_id: id)

  # `created_by_user_id` is the ownership pointer for signed-in creators
  # (ADR-0002). Also mass-assignment-protected: accepting it from params would
  # let anyone hand themselves ownership of anything by id. Set at creation
  # from the server-held `:current_user_id` in the session, or moved by the
  # admin via `Events.set_created_by/2`.
  @doc false
  def put_created_by_user_id(%Event{} = event, nil),
    do: change(event, created_by_user_id: nil)

  def put_created_by_user_id(%Event{} = event, id) when is_integer(id),
    do: change(event, created_by_user_id: id)

  defp validate_ends_after_starts(changeset) do
    starts_at = get_field(changeset, :starts_at)
    ends_at = get_field(changeset, :ends_at)

    if starts_at && ends_at && DateTime.compare(ends_at, starts_at) != :gt do
      add_error(changeset, :ends_at, "precisa ser depois do início")
    else
      changeset
    end
  end

  @doc "Valid values for the `split_method` enum, in the order the form lists them."
  def split_methods, do: @split_methods

  @doc "The label for a `split_method` — what the form and the shared text call it."
  @spec split_method_label(split_method()) :: String.t()
  def split_method_label(:total_split), do: "Dividir automaticamente total"
  def split_method_label(:per_person), do: "Preço por participante"
  def split_method_label(:per_seat), do: "Preço por participante (inclui vazios)"
  def split_method_label(:settle_up), do: "Dividir no final"

  @doc "Valid values for the `status` enum."
  def statuses, do: @statuses

  @doc "Statuses visible on the public home page."
  def open_statuses, do: @open_statuses

  @doc "Statuses reachable by anonymous visitors with the slug."
  def public_statuses, do: @public_statuses

  @doc "The short label for the `:maybe` status."
  @spec maybe_status_label() :: String.t()
  def maybe_status_label, do: "Averiguando Resenha"

  @doc """
  The one-liner explaining the `:maybe` status to viewers.

  Kept here (schema module) so every surface — pill tooltip on cards,
  banner on the event page, admin edit form — tells the same story. If
  this string ever gets translated or A/B'd, the single call site is the
  only place to change.
  """
  @spec maybe_status_hint() :: String.t()
  def maybe_status_hint,
    do:
      "Rolê que pode ou não rolar, depende de quem confirmar. Entra na lista pra ajudar a decidir."

  @doc "Returns true when the event blocks non-admin signups (payments-only state)."
  @spec locked_signups?(t()) :: boolean()
  def locked_signups?(%Event{status: :payments_only}), do: true
  def locked_signups?(%Event{}), do: false

  @doc "Returns true when the event has a password set."
  @spec password_protected?(t()) :: boolean()
  def password_protected?(%Event{password: p}) when is_binary(p) and p != "", do: true
  def password_protected?(%Event{}), do: false

  # Empty strings collapse to nil so the DB stores "no password" as NULL.
  defp normalize_password(nil), do: nil

  defp normalize_password(str) when is_binary(str) do
    case String.trim(str) do
      "" -> nil
      other -> other
    end
  end

  defp normalize_password(_), do: nil

  @doc "Regex used to validate slug values."
  def slug_regex, do: @slug_regex

  # ---------- Text renderers ----------

  @doc """
  Serializes an %Event{} into the pretty markdown form that used to live on disk.
  Still used as the initial value for the raw editor and for exports.
  """
  @spec render(t()) :: String.t()
  def render(%Event{} = event) do
    title_line = "# " <> String.trim(event.title || "")

    parts = [title_line]

    parts =
      if event.header != "" and event.header != nil do
        parts ++ ["", event.header]
      else
        parts
      end

    parts = parts ++ ["", render_list(event.main_list, event.main_capacity)]

    parts =
      if event.wait_enabled do
        intro = event.wait_intro |> to_string() |> String.trim()
        intro = if intro == "", do: "Lista de reserva", else: intro
        parts ++ ["", intro, render_wait_list(event.wait_list)]
      else
        parts
      end

    parts =
      if event.footer != "" and event.footer != nil do
        parts ++ ["", event.footer]
      else
        parts
      end

    parts
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  @doc """
  Produces the shareable/raw text representation people can copy or share.

  Prepends the given URL as the first line, drops the leading `# ` from the title,
  and replaces empty list slots with a compact summary line:

    * `3 vagas: <url>` (or `1 vaga: <url>`) after the main list when there is
      still room. Nothing is added when the main list is full.
    * `Entrar na espera: <url>` after the wait list (always present when the
      wait list is enabled, since it is infinite).

  Opts:

    * `:strip_location` — when true, removes the `Local:` line from the header.
      Used for password-protected events viewed by non-unlocked users.
    * `:hide_description` — when true, omits the entire header (meta lines and
      free-form description) from the output. Takes precedence over
      `:strip_location`.
    * `:hide_names` — when true, replaces every filled attendee name with the
      `•••` placeholder (empty slots stay empty). Paid marks are preserved.
    * `:include_password` — when true and the event has a password set, inserts
      a `Senha: <password>` line right below the URL so shared messages can
      bundle the link and the password together.

  Payments-only events omit the vagas/espera summary lines automatically, since
  in that mode signups are closed.

  The payment line (`Rolezinho.Event.Cash.amount_line_text/1`) follows the
  header, and is omitted together with it under `:hide_description`.
  """
  @spec to_text(t(), String.t() | nil, keyword()) :: String.t()
  def to_text(%Event{} = event, url \\ nil, opts \\ []) do
    title_line = String.trim(event.title || "")
    strip_location? = Keyword.get(opts, :strip_location, false)
    hide_description? = Keyword.get(opts, :hide_description, false)
    include_password? = Keyword.get(opts, :include_password, false)

    parts =
      case url do
        nil -> []
        "" -> []
        u -> [u, ""]
      end

    # Bundle the password right below the URL for easy sharing.
    parts =
      if include_password? and password_protected?(event) do
        # Replace the trailing blank line with the password line + blank.
        List.delete_at(parts, -1) ++ ["Senha: #{event.password}", ""]
      else
        parts
      end

    parts = parts ++ [title_line]

    header =
      cond do
        hide_description? -> nil
        event.header in ["", nil] -> nil
        strip_location? -> strip_local_line(event.header)
        true -> event.header
      end

    parts =
      if header && header != "" do
        parts ++ ["", header]
      else
        parts
      end

    hide_names? = Keyword.get(opts, :hide_names, false)

    parts =
      case {hide_description?, Cash.amount_line_text(event)} do
        {false, line} when is_binary(line) -> parts ++ ["", line]
        _ -> parts
      end

    parts = parts ++ settlement_text(event, hide_description? or hide_names?)

    parts = parts ++ ["", main_list_text(event, url, hide_names?)]

    parts =
      if event.wait_enabled do
        intro = event.wait_intro |> to_string() |> String.trim()
        intro = if intro == "", do: "Lista de reserva", else: intro
        parts ++ ["", intro, wait_list_text(event, url, hide_names?)]
      else
        parts
      end

    parts =
      if event.footer != "" and event.footer != nil do
        parts ++ ["", event.footer]
      else
        parts
      end

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp main_list_text(%Event{} = event, url, hide_names?) do
    filled = compact_main(event.main_list)
    free = event.main_capacity - length(filled)

    lines =
      filled
      |> Enum.with_index(1)
      |> Enum.map(fn {%Attendee{} = att, i} ->
        render_attendee_line(i, att, hide_names?, contribution_suffix(event, att, hide_names?))
      end)

    lines =
      if free > 0 and not locked_signups?(event) do
        lines ++ [vagas_line(free, url)]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp wait_list_text(%Event{} = event, url, hide_names?) do
    lines =
      event.wait_list
      |> Enum.with_index(1)
      |> Enum.map(fn {%Attendee{} = att, i} -> render_attendee_line(i, att, hide_names?) end)

    trailer = if locked_signups?(event), do: [], else: [entrar_espera_line(url)]

    Enum.join(lines ++ trailer, "\n")
  end

  # Drops any header line whose canonical label is `Local:` (case-insensitive).
  defp strip_local_line(header) when is_binary(header) do
    header
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&Regex.match?(~r/^\s*local\s*:/iu, &1))
    |> Enum.join("\n")
    |> String.trim("\n")
  end

  @doc false
  def vagas_line(count, url) do
    label = if count == 1, do: "1 vaga", else: "#{count} vagas"
    if is_binary(url) and url != "", do: "#{label}: #{url}", else: label
  end

  @doc false
  def entrar_espera_line(url) do
    if is_binary(url) and url != "",
      do: "Entrar na espera: #{url}",
      else: "Entrar na espera"
  end

  # ---------- Pure list operations ----------

  @doc "Ensures the main list has exactly `capacity` slots (padding with empty)."
  @spec normalize_main(t()) :: t()
  def normalize_main(%Event{} = event) do
    filled = compact_main(event.main_list)
    capacity = max(event.main_capacity, length(filled))
    padded = pad(filled, capacity)
    %{event | main_capacity: capacity, main_list: padded}
  end

  @doc "Adds an attendee to the first empty main slot."
  @spec add_to_main(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def add_to_main(%Event{} = event, name, opts \\ []) do
    name = clean_name(name)

    cond do
      name == "" ->
        {:error, :empty_name}

      main_full?(event) ->
        {:error, :main_full}

      true ->
        list = replace_first_empty(event.main_list, new_attendee(name, opts))
        {:ok, %{event | main_list: list}}
    end
  end

  # Identity travels with the row from the moment it is created. The
  # `participant_id` is the per-device token; `user_id` (ADR-0002) is the
  # signed-in GitHub user, when one is present. Either or both may be nil.
  defp new_attendee(name, opts) do
    %Attendee{
      name: name,
      paid: false,
      participant_id: Keyword.get(opts, :participant_id),
      user_id: Keyword.get(opts, :user_id),
      joined_at: DateTime.utc_now(:second),
      values: Keyword.get(opts, :values, %{})
    }
  end

  @doc """
  Adds someone and their companions in one action (RN-04).

  Each person becomes a row of their own, because a slot holds one person: a
  single row saying "Márcia +2" would let three people occupy one place and the
  count would lie. The companions are named after whoever brought them
  ("Convidado de Márcia"), which is also who owes for them.

  When the party does not fit, the overflow goes to the waiting list in the same
  action rather than failing — someone bringing two friends should not have to
  guess how many slots were left and retry.

  Returns `{:ok, event, placed}` where `placed` says how many landed in each
  list, so the caller can tell the person what actually happened.
  """
  @spec add_party(t(), String.t(), pos_integer(), keyword()) ::
          {:ok, t(), %{main: non_neg_integer(), wait: non_neg_integer()}} | {:error, atom()}
  def add_party(%Event{} = event, name, size, opts \\ []) when is_integer(size) do
    name = clean_name(name)

    cond do
      name == "" -> {:error, :empty_name}
      size < 1 or size > max_party_size() -> {:error, :invalid_party_size}
      true -> place_party(event, name, size, opts)
    end
  end

  @doc "The largest party one person can bring in a single join (RN-04)."
  def max_party_size, do: 9

  defp place_party(%Event{} = event, name, size, opts) do
    guest_names = Keyword.get(opts, :guest_names, [])
    names = party_names(name, size, guest_names)
    {for_main, overflow} = Enum.split(names, free_main_slots(event))

    # Without a waiting list there is nowhere for the overflow to go. Taking the
    # first few and silently dropping the rest would be worse than refusing:
    # someone would believe their friends are in.
    for_wait = if event.wait_enabled, do: overflow, else: []

    cond do
      for_main == [] and for_wait == [] and event.wait_enabled ->
        {:error, :main_full}

      for_main == [] and overflow != [] and not event.wait_enabled ->
        {:error, :main_full}

      overflow != [] and not event.wait_enabled ->
        {:error, :party_does_not_fit}

      true ->
        # The answers belong to whoever filled in the form, and they are the
        # first row placed — which is in the waiting list when the main one was
        # already full.
        wait_opts = if for_main == [], do: opts, else: Keyword.delete(opts, :values)

        with {:ok, event} <- add_each(event, for_main, opts, &add_to_main/3),
             {:ok, event} <- add_each(event, for_wait, wait_opts, &add_to_wait/3) do
          {:ok, event, %{main: length(for_main), wait: length(for_wait)}}
        end
    end
  end

  # The person who joined keeps their name; each guest gets whatever the
  # form typed for that position, or falls back to "Convidado de X" (which
  # is how the group refers to them when nobody bothered to name them and
  # who settles up).
  defp party_names(name, 1, _guests), do: [name]

  defp party_names(name, size, guests) do
    fallbacks = Enum.map(2..size, fn _ -> "Convidado de #{name}" end)
    typed = Enum.map(guests, &clean_name/1)

    guest_names =
      fallbacks
      |> Enum.with_index()
      |> Enum.map(fn {fallback, index} ->
        case Enum.at(typed, index) do
          "" -> fallback
          nil -> fallback
          value -> value
        end
      end)

    [name | guest_names]
  end

  # The whole party shares one participant_id: it came from one browser, and the
  # person who joined is the one who can act on all of those rows.
  defp add_each(event, names, opts, add) do
    names
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, event}, fn {name, index}, {:ok, acc} ->
      case add.(acc, name, row_opts(opts, index)) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Only the person who filled in the form carries the answers. Copying them
  # onto the companions would invent data nobody gave — the guests never
  # answered a shirt size.
  defp row_opts(opts, 0), do: opts
  defp row_opts(opts, _index), do: Keyword.delete(opts, :values)

  defp free_main_slots(%Event{main_list: list}) do
    Enum.count(list, &(String.trim(&1.name) == ""))
  end

  @doc "Adds an attendee to the end of the wait list."
  @spec add_to_wait(t(), String.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def add_to_wait(%Event{} = event, name, opts \\ []) do
    name = clean_name(name)

    cond do
      name == "" ->
        {:error, :empty_name}

      not event.wait_enabled ->
        {:error, :wait_disabled}

      true ->
        {:ok, %{event | wait_list: event.wait_list ++ [new_attendee(name, opts)]}}
    end
  end

  @doc "Removes and shifts everyone up in the main list (1-based index)."
  @spec remove_main(t(), pos_integer()) :: t()
  def remove_main(%Event{} = event, index) do
    new_list =
      event.main_list
      |> List.delete_at(index - 1)
      |> Kernel.++([%Attendee{}])
      |> Enum.take(event.main_capacity)

    %{event | main_list: compact_then_pad(new_list, event.main_capacity)}
  end

  @doc "Removes an attendee from the wait list (1-based)."
  @spec remove_wait(t(), pos_integer()) :: t()
  def remove_wait(%Event{} = event, index) do
    %{event | wait_list: List.delete_at(event.wait_list, index - 1)}
  end

  @doc "Toggles the paid flag on a main list attendee (1-based)."
  @spec toggle_paid_main(t(), pos_integer()) :: t()
  def toggle_paid_main(%Event{} = event, index) do
    list = update_at(event.main_list, index - 1, fn att -> %{att | paid: !att.paid} end)
    %{event | main_list: list}
  end

  @doc "Toggles the paid flag on a wait list attendee."
  @spec toggle_paid_wait(t(), pos_integer()) :: t()
  def toggle_paid_wait(%Event{} = event, index) do
    list = update_at(event.wait_list, index - 1, fn att -> %{att | paid: !att.paid} end)
    %{event | wait_list: list}
  end

  @doc "Renames a main list attendee."
  @spec rename_main(t(), pos_integer(), String.t()) :: t()
  def rename_main(%Event{} = event, index, name) do
    name = clean_name(name)
    list = update_at(event.main_list, index - 1, fn att -> %{att | name: name} end)
    %{event | main_list: list}
  end

  @doc "Renames a wait list attendee."
  @spec rename_wait(t(), pos_integer(), String.t()) :: t()
  def rename_wait(%Event{} = event, index, name) do
    name = clean_name(name)
    list = update_at(event.wait_list, index - 1, fn att -> %{att | name: name} end)
    %{event | wait_list: list}
  end

  @doc """
  Updates a main-list attendee's name and/or form answers in place.

  `attrs` may carry:

    * `:name` — a string; if omitted the current name is kept. Cleaned
      through `clean_name/1` so an all-whitespace value never blanks a
      row (mirroring `rename_main/3`'s guardrail).
    * `:values` — a map keyed by form-field id; **replaces** the current
      values entirely (the caller is responsible for merging what to keep).
      Callers going through `Rolezinho.Events.update_main/3` get that
      merging + sanitizing for free.

  Empty attrs (`%{}`) is a no-op and returns the event unchanged — handy
  for controllers that receive nothing to change and want to short-circuit.
  """
  @spec update_main(t(), pos_integer(), map()) :: t()
  def update_main(%Event{} = event, index, attrs) when is_map(attrs) do
    list = update_at(event.main_list, index - 1, &apply_row_updates(&1, attrs))
    %{event | main_list: list}
  end

  @doc """
  Same as `update_main/3`, for a wait-list row.
  """
  @spec update_wait(t(), pos_integer(), map()) :: t()
  def update_wait(%Event{} = event, index, attrs) when is_map(attrs) do
    list = update_at(event.wait_list, index - 1, &apply_row_updates(&1, attrs))
    %{event | wait_list: list}
  end

  # A blank/whitespace `:name` falls back to the current one so an owner
  # editing only their answer never blanks the row. Missing `:values` is
  # left untouched; an explicit `values: %{}` clears every answer, which
  # is the honest interpretation of "the sanitized map came back empty".
  defp apply_row_updates(%Attendee{} = attendee, attrs) do
    attendee
    |> maybe_update_name(Map.get(attrs, :name))
    |> maybe_update_values(Map.get(attrs, :values, :__missing__))
  end

  defp maybe_update_name(%Attendee{} = attendee, nil), do: attendee

  defp maybe_update_name(%Attendee{} = attendee, value) when is_binary(value) do
    case clean_name(value) do
      "" -> attendee
      cleaned -> %{attendee | name: cleaned}
    end
  end

  defp maybe_update_values(%Attendee{} = attendee, :__missing__), do: attendee

  defp maybe_update_values(%Attendee{} = attendee, values) when is_map(values),
    do: %{attendee | values: values}

  @doc "Promotes the wait list entry at `index` (1-based) to the first empty main slot."
  @spec promote(t(), pos_integer()) :: {:ok, t()} | {:error, atom()}
  def promote(%Event{} = event, index) do
    cond do
      main_full?(event) ->
        {:error, :main_full}

      Enum.at(event.wait_list, index - 1) == nil ->
        {:error, :not_found}

      true ->
        # `paid` is cleared on the way in: nobody on the queue owes anything, so
        # a truthy flag there can only be stale, and carrying it over would put
        # someone on the main list already marked as having paid.
        %Attendee{} = person = %{Enum.at(event.wait_list, index - 1) | paid: false}
        new_wait = List.delete_at(event.wait_list, index - 1)
        new_main = replace_first_empty(event.main_list, person)
        {:ok, %{event | main_list: new_main, wait_list: new_wait}}
    end
  end

  @doc """
  Resizes the main list. When growing, appends empty slots. When shrinking,
  clamps to the number of filled attendees (never removes anyone).
  """
  @spec resize_main(t(), integer()) :: t()
  def resize_main(%Event{} = event, requested) when is_integer(requested) do
    filled = compact_main(event.main_list)
    new_capacity = max(requested, length(filled))
    %{event | main_capacity: new_capacity, main_list: pad(filled, new_capacity)}
  end

  @doc "How many main slots are still empty."
  @spec main_free_slots(t()) :: non_neg_integer()
  def main_free_slots(%Event{} = event) do
    event.main_capacity - length(compact_main(event.main_list))
  end

  @doc "True when the main list has no empty slots."
  @spec main_full?(t()) :: boolean()
  def main_full?(%Event{} = event), do: main_free_slots(event) <= 0

  # ---------- Serialization helpers ----------

  @doc """
  Converts the attendee lists in an event struct into plain maps, suitable for
  passing back into `changeset/2` as attrs.
  """
  @spec attrs_from_struct(t()) :: map()
  def attrs_from_struct(%Event{} = event) do
    %{
      slug: event.slug,
      title: event.title,
      status: event.status,
      hidden: event.hidden,
      header: event.header,
      footer: event.footer,
      main_capacity: event.main_capacity,
      wait_enabled: event.wait_enabled,
      wait_intro: event.wait_intro,
      password: event.password,
      category: event.category,
      local: event.local,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      split_method: event.split_method,
      price_cents: event.price_cents,
      total_cents: event.total_cents,
      pix_key: event.pix_key,
      pix_key_type: event.pix_key_type,
      main_list: Enum.map(event.main_list, &attendee_to_map/1),
      wait_list: Enum.map(event.wait_list, &attendee_to_map/1),
      form_fields: Enum.map(event.form_fields, &Map.from_struct/1)
    }
  end

  # Every field of the row round-trips: this map is what a save rebuilds the
  # event from, so anything omitted here is silently dropped on the next write.
  # Losing participant_id would quietly unclaim the row from the person holding
  # it.
  # Every field of the row round-trips: this map is what a save rebuilds the
  # event from, so anything omitted here is silently dropped on the next write.
  # Losing `participant_id` or `user_id` would quietly unclaim the row from
  # its owner.
  defp attendee_to_map(%Attendee{} = attendee) do
    %{
      name: attendee.name,
      paid: attendee.paid,
      contributed_cents: attendee.contributed_cents,
      pix_key: attendee.pix_key,
      participant_id: attendee.participant_id,
      user_id: attendee.user_id,
      joined_at: attendee.joined_at,
      values: attendee.values
    }
  end

  # ---------- Rendering helpers ----------

  defp render_list(list, capacity) do
    slots = pad(compact_main(list), capacity)

    slots
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {%Attendee{} = att, i} -> render_attendee_line(i, att) end)
  end

  defp render_wait_list([]), do: "1-"

  defp render_wait_list(list) do
    list
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {%Attendee{} = att, i} -> render_attendee_line(i, att) end)
  end

  @hidden_name_placeholder "•••"

  @doc "Placeholder used when attendee names must be hidden (locked view)."
  def hidden_name_placeholder, do: @hidden_name_placeholder

  defp render_attendee_line(i, att, hide_names? \\ false, suffix \\ "")

  defp render_attendee_line(i, %Attendee{name: "", paid: _}, _hide?, _suffix), do: "#{i}- "

  defp render_attendee_line(i, %Attendee{name: name, paid: paid}, hide?, suffix) do
    display = if hide?, do: @hidden_name_placeholder, else: name
    mark = if paid, do: " ✅", else: ""
    "#{i}- #{display}#{suffix}#{mark}"
  end

  # "Dividir no final": who sends what to whom, one line per sender, with the
  # sender's ✅ once they say they sent it. Left out whenever names are, since
  # the plan is nothing but names.
  defp settlement_text(%Event{split_method: :settle_up} = event, false = _hidden?) do
    case Settlement.by_sender(Settlement.plan(event)) do
      [] ->
        []

      groups ->
        lines =
          Enum.map(groups, fn {sender, transfers} ->
            amounts =
              Enum.map_join(transfers, " e ", fn transfer ->
                "#{Cash.format_amount(transfer.cents)} para #{transfer.to.name}"
              end)

            "#{sender.name} manda #{amounts}" <> if(sender.paid, do: " ✅", else: "")
          end)

        ["", "Plano de pagamento" | lines] ++ receiver_pix_text(Settlement.plan(event))
    end
  end

  defp settlement_text(%Event{}, _hidden?), do: []

  # One block with each receiver's key, rather than the key repeated on every
  # line that pays them — five "(Pix: …)" in a row is noise in a group chat.
  defp receiver_pix_text(plan) do
    case Enum.filter(Settlement.receivers(plan), & &1.pix_key) do
      [] -> []
      receivers -> ["", "Pix de quem recebe" | Enum.map(receivers, &"#{&1.name}: #{&1.pix_key}")]
    end
  end

  defp contribution_suffix(
         %Event{split_method: :settle_up},
         %Attendee{contributed_cents: cents},
         false = _hide_names?
       )
       when is_integer(cents) and cents > 0,
       do: " (pagou #{Cash.format_amount(cents)})"

  defp contribution_suffix(%Event{}, %Attendee{}, _hide_names?), do: ""

  defp compact_main(list) do
    Enum.reject(list, fn %Attendee{name: n} -> String.trim(n) == "" end)
  end

  defp compact_then_pad(list, capacity) do
    list
    |> compact_main()
    |> pad(capacity)
  end

  defp pad(list, capacity) when length(list) >= capacity, do: Enum.take(list, capacity)
  defp pad(list, capacity), do: list ++ List.duplicate(%Attendee{}, capacity - length(list))

  defp replace_first_empty(list, replacement) do
    {new, _replaced?} =
      Enum.map_reduce(list, false, fn
        att, false ->
          if String.trim(att.name) == "" do
            {replacement, true}
          else
            {att, false}
          end

        att, true ->
          {att, true}
      end)

    new
  end

  @doc """
  Records what the main-list attendee at `index` (1-based) spent, in cents,
  and the Pix key they want to be paid back on (`nil` for none).
  """
  @spec set_contribution(t(), pos_integer(), non_neg_integer(), String.t() | nil) :: t()
  def set_contribution(%Event{} = event, index, cents, pix_key)
      when is_integer(cents) and cents >= 0 do
    list =
      update_at(event.main_list, index - 1, fn att ->
        %{att | contributed_cents: cents, pix_key: pix_key}
      end)

    %{event | main_list: list}
  end

  defp update_at(list, index, fun) do
    List.update_at(list, index, fn
      nil -> nil
      %Attendee{} = att -> fun.(att)
    end)
  end

  defp clean_name(nil), do: ""

  defp clean_name(name) do
    name
    |> to_string()
    |> String.replace(~r/[\r\n]+/u, " ")
    |> String.trim()
  end
end
