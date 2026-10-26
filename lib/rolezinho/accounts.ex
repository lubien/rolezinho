defmodule Rolezinho.Accounts do
  @moduledoc """
  Context for user accounts.

  Two identity paths land here (ADR-0002, amended 2026-09):

    * **GitHub OAuth** — `find_or_create_by_github/1` upserts by
      `github_id`, refreshing `github_login`/`name`/`avatar_url` on
      every sign-in. On first insert it auto-derives a `:username`
      from `lower(github_login)`, suffixing with a number on collision
      with an existing local-auth user.

    * **Local username + password** — `register_user/1` inserts a row
      keyed on `:username` with a bcrypt `:password_hash`.
      `authenticate_user/2` verifies the pair in constant time.

  Both paths produce the same session (`:current_user_id`) and the
  same downstream widening (`user.admin` flips `:current_admin?`,
  persisted group unlocks merge into `:unlocked_groups`).
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Rolezinho.Accounts.ApiKey
  alias Rolezinho.Accounts.PasswordResetToken
  alias Rolezinho.Accounts.User
  alias Rolezinho.Accounts.UserNotifier
  alias Rolezinho.Repo

  # Reset tokens live for one hour. Long enough that a user who
  # switches tabs and comes back after lunch still has time; short
  # enough that a leaked reset URL closes on its own within a work
  # session. Enforced by the context, not the DB.
  @reset_token_ttl_seconds 60 * 60

  # 32 bytes of randomness before base64 = 43 URL-safe chars. Enough
  # entropy that guessing is not a threat model. What lands in the DB
  # is `:crypto.hash(:sha256, token)`, so a DB dump does not translate
  # to instant reset ability.
  @reset_token_bytes 32

  # API-key tokens are also 32 bytes of randomness. Prefix `rk_live_`
  # is prepended so a leaked key is instantly identifiable in logs
  # and the first 16 chars (prefix + 8 of randomness) are safe to
  # display in the UI as a tag.
  @api_key_bytes 32
  @api_key_prefix "rk_live_"
  @api_key_prefix_display_len 16

  @doc """
  Loads a user by primary key. Returns `nil` when not found (or when `nil` is
  passed, so the session-key `:current_user_id` can be piped in without
  branching).
  """
  @spec get_user(integer() | nil) :: User.t() | nil
  def get_user(nil), do: nil
  def get_user(id) when is_integer(id), do: Repo.get(User, id)

  @doc """
  Finds a user by their numeric GitHub id. Returns `nil` when not found.
  """
  @spec get_by_github_id(integer()) :: User.t() | nil
  def get_by_github_id(github_id) when is_integer(github_id) do
    Repo.get_by(User, github_id: github_id)
  end

  @doc """
  Upserts a user from a normalized GitHub OAuth response.

  `attrs` is expected to have string keys `"github_id"`, `"github_login"`, and
  optionally `"name"`, `"email"`, `"avatar_url"`. Missing optional values map
  to `nil`, matching what GitHub itself sometimes returns for private profiles.

  On the second and subsequent calls for the same `github_id`, the existing
  row is refreshed — no duplicate is ever created.
  """
  @spec find_or_create_by_github(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_by_github(attrs) when is_map(attrs) do
    github_id = attrs |> Map.get("github_id") |> to_integer()

    if is_nil(github_id) do
      # Constructing an explicit changeset lets the caller surface the error the
      # same way as any other validation failure, rather than a `nil` matching
      # error deep in Ecto.
      {:error,
       User.github_changeset(%User{}, attrs)
       |> Changeset.add_error(:github_id, "obrigatório")}
    else
      case get_by_github_id(github_id) do
        nil ->
          # Insert path: auto-derive a `:username` from `github_login`
          # and suffix on collision. `github_login` is already unique
          # per-GitHub-user, so the pool of candidates is small; the
          # loop caps at 100 tries and gives up loudly if we somehow
          # exhaust it (which means production has bigger problems).
          attrs =
            Map.put(attrs, "username", derive_username(Map.get(attrs, "github_login")))

          %User{} |> User.github_changeset(attrs) |> Repo.insert()

        %User{} = user ->
          user |> User.github_changeset(attrs) |> Repo.update()
      end
    end
  end

  # Turns a GitHub login into a valid, unique local username. Same
  # normalization the schema does (`lower`), plus a suffix on
  # collision with an existing local-auth user. Prod audit before
  # ship (2026-09) showed zero collisions on lower(github_login), so
  # the suffix path is defensive rather than routine.
  defp derive_username(nil), do: nil

  defp derive_username(github_login) when is_binary(github_login) do
    base =
      github_login
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_.-]/u, "")

    base =
      cond do
        base == "" -> "user"
        # Schema regex requires the username to start with a letter;
        # a GitHub login starting with a digit gets prefixed.
        String.match?(base, ~r/^[a-z]/) -> base
        true -> "u-" <> base
      end

    # Pad to the 6-char minimum so a short handle ("me", "ex") still
    # satisfies the length rule. Padding character is `0`, matching
    # the allowed alphabet.
    base = String.pad_trailing(base, 6, "0")

    unique_username(base, 0, 100)
  end

  defp unique_username(_base, tries, tries), do: raise("could not derive a unique username")

  defp unique_username(base, n, max_tries) do
    candidate = if n == 0, do: base, else: "#{base}#{n}"

    case Repo.get_by(User, username: candidate) do
      nil -> candidate
      %User{} -> unique_username(base, n + 1, max_tries)
    end
  end

  @doc """
  Case-insensitive lookup by `:username`. The username column stores
  lowercase (see `User.register_changeset/2`) so a downcase on the way
  in is enough — no need for a `lower(?)` SQL fragment here.
  """
  @spec get_by_username(String.t()) :: User.t() | nil
  def get_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: String.downcase(String.trim(username)))
  end

  def get_by_username(_), do: nil

  @doc """
  Registers a new local-auth user from a params map.

  Expected string keys: `"username"`, `"password"`, and optionally
  `"email"` and `"name"`. Password rules and username format live on
  the schema (see `User.register_changeset/2`).

  Returns `{:ok, user}` on success and `{:error, changeset}` on
  validation failure (invalid username, duplicate username, weak
  password, etc.). The controller re-renders the form with the
  changeset's errors attached to the fields.
  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Changeset.t()}
  def register_user(attrs) when is_map(attrs) do
    %User{}
    |> User.register_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Verifies a `(username, password)` pair.

  Returns `{:ok, user}` on match, `{:error, :invalid_credentials}` on
  anything else — missing user, missing password_hash (GitHub-only
  account), or wrong password.

  Constant-time: when the user is missing we still run a dummy bcrypt
  verify via `Bcrypt.no_user_verify/0` so the timing signal doesn't
  reveal whether a username exists.
  """
  @spec authenticate_user(String.t() | nil, String.t() | nil) ::
          {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate_user(username, password) when is_binary(username) and is_binary(password) do
    case get_by_username(username) do
      %User{password_hash: hash} = user when is_binary(hash) ->
        if Bcrypt.verify_pass(password, hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end

      _ ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  def authenticate_user(_username, _password) do
    Bcrypt.no_user_verify()
    {:error, :invalid_credentials}
  end

  @doc """
  Sets or replaces a user's password.

  If the user already has a `:password_hash`, the caller must supply
  `current_password` and it must match (so a stolen session can't
  quietly reset the password); if they don't, a first-time password
  is fine without the check. Meant to be called from `/me` by the
  signed-in user themselves.
  """
  @spec update_password(User.t(), String.t() | nil, String.t()) ::
          {:ok, User.t()} | {:error, :invalid_current_password | Changeset.t()}
  def update_password(%User{password_hash: hash} = user, current_password, new_password)
      when is_binary(hash) do
    if is_binary(current_password) and Bcrypt.verify_pass(current_password, hash) do
      do_update_password(user, new_password)
    else
      Bcrypt.no_user_verify()
      {:error, :invalid_current_password}
    end
  end

  def update_password(%User{} = user, _current_password, new_password) do
    do_update_password(user, new_password)
  end

  defp do_update_password(%User{} = user, new_password) do
    user
    |> User.password_changeset(%{"password" => new_password})
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Updates a signed-in user's email address.

  Accepts a plain string. Trimming + empty-collapse-to-nil happens in
  the changeset, so a whitespace-only value clears the email (which
  is a valid state — email is optional).

  Returns `{:ok, user}` on success and `{:error, %Ecto.Changeset{}}`
  on validation failure (currently only length).
  """
  @spec update_email(User.t(), String.t() | nil) :: {:ok, User.t()} | {:error, Changeset.t()}
  def update_email(%User{} = user, new_email) do
    user
    |> User.email_changeset(%{"email" => new_email})
    |> Repo.update()
  end

  # ---------- Password reset ----------

  @doc """
  Requests a password-reset link.

  Accepts a username or an email. Always returns `:ok` regardless of
  whether a user was found or an email was actually sent — the
  callsite must not leak whether an account exists (RFC 8628 style,
  and consistent with the login flow's opaque "usuário ou senha
  inválidos"). Inserts a fresh token and mails the reset URL when:

    * the identifier resolves to a user, AND
    * the user has an `:email` on file.

  Any prior unused tokens for the same user are deleted first, so at
  most one active reset link exists per user at a time — the last
  request wins.

  `url_builder` is a 1-arity function that turns the plaintext token
  into an absolute URL. Passed in by the controller so this module
  does not depend on the router.
  """
  @spec request_password_reset(String.t() | nil, (String.t() -> String.t())) :: :ok
  def request_password_reset(identifier, url_builder) when is_function(url_builder, 1) do
    case resolve_reset_target(identifier) do
      %User{email: email} = user when is_binary(email) and email != "" ->
        {token, hash} = generate_reset_token()

        # Wipe any prior outstanding token for this user, then insert
        # the new one. In one transaction so a crash mid-request never
        # leaves the user with two live tokens.
        {:ok, _} =
          Multi.new()
          |> Multi.delete_all(
            :delete_prior,
            from(t in PasswordResetToken, where: t.user_id == ^user.id)
          )
          |> Multi.insert(
            :insert_token,
            PasswordResetToken.new_changeset(%{
              user_id: user.id,
              token_hash: hash,
              sent_to_email: email,
              expires_at: reset_token_expiry()
            })
          )
          |> Repo.transaction()

        # Best-effort delivery. A transport error is logged silently:
        # the caller must not learn whether the address bounced.
        _ = UserNotifier.deliver_reset_password_instructions(user, url_builder.(token))

        :ok

      _ ->
        # No user, or user with no email. Still consume a token-hash
        # to keep the timing profile in the same ballpark as the
        # happy path (bcrypt-style "do the work anyway" trick).
        _ = generate_reset_token()
        :ok
    end
  end

  @doc """
  Redeems a reset token and sets a new password in one transaction.

  Returns:

    * `{:ok, user}` on success — the token is marked used, the
      password hash is replaced, and the reloaded user is returned.
    * `{:error, :invalid_token}` if the token doesn't exist, is
      expired, or has already been used.
    * `{:error, %Ecto.Changeset{}}` if the new password fails
      validation.

  The plaintext token is never stored; this function hashes what the
  caller provides and looks up by hash. All prior outstanding tokens
  for the user (including the one just redeemed) are deleted on
  success — so a link, once used, is dead everywhere.
  """
  @spec reset_password_with_token(String.t() | nil, String.t()) ::
          {:ok, User.t()} | {:error, :invalid_token | Changeset.t()}
  def reset_password_with_token(token, new_password)
      when is_binary(token) and is_binary(new_password) do
    case fetch_valid_reset_token(token) do
      {:ok, %PasswordResetToken{user_id: user_id}} ->
        user = Repo.get!(User, user_id)
        hash = hash_token(token)

        Multi.new()
        |> Multi.update(:user, User.password_changeset(user, %{"password" => new_password}))
        |> Multi.delete_all(
          :delete_tokens,
          from(t in PasswordResetToken, where: t.user_id == ^user.id or t.token_hash == ^hash)
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{user: updated}} -> {:ok, updated}
          {:error, :user, changeset, _} -> {:error, changeset}
        end

      :error ->
        {:error, :invalid_token}
    end
  end

  def reset_password_with_token(_token, _new_password), do: {:error, :invalid_token}

  @doc """
  Loads the user associated with a valid reset token, or returns
  `:error`.

  Same validity rules as the redeem path (exists, not expired, not
  used), but does not consume the token — used by the reset-form
  screen to decide whether to render the form or a "link expired"
  message before the user has typed anything.
  """
  @spec fetch_user_by_reset_token(String.t() | nil) :: {:ok, User.t()} | :error
  def fetch_user_by_reset_token(token) when is_binary(token) do
    case fetch_valid_reset_token(token) do
      {:ok, %PasswordResetToken{user_id: user_id}} ->
        case Repo.get(User, user_id) do
          %User{} = user -> {:ok, user}
          nil -> :error
        end

      :error ->
        :error
    end
  end

  def fetch_user_by_reset_token(_), do: :error

  # Resolves a free-form identifier to a user. Accepts a username (the
  # canonical, lowercase-normalized handle) OR an email. Order matters:
  # try username first because it's the primary identity; only fall
  # back to email if that fails. Both lookups are case-insensitive.
  defp resolve_reset_target(nil), do: nil
  defp resolve_reset_target(""), do: nil

  defp resolve_reset_target(identifier) when is_binary(identifier) do
    trimmed = String.trim(identifier)

    cond do
      trimmed == "" ->
        nil

      String.contains?(trimmed, "@") ->
        get_by_email(trimmed) || get_by_username(trimmed)

      true ->
        get_by_username(trimmed) || get_by_email(trimmed)
    end
  end

  defp resolve_reset_target(_), do: nil

  # Case-insensitive email lookup. The `:email` column is not unique on
  # this project (two GitHub accounts can share a private email in
  # theory, and email is optional / unverified), so this returns the
  # first match — which is stable enough for a reset request path
  # (the same email means the same physical inbox, whoever the row
  # picked belongs to).
  defp get_by_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    Repo.one(
      from u in User,
        where: fragment("lower(?) = ?", u.email, ^normalized),
        order_by: [asc: u.id],
        limit: 1
    )
  end

  defp fetch_valid_reset_token(token) when is_binary(token) do
    hash = hash_token(token)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(PasswordResetToken, token_hash: hash) do
      %PasswordResetToken{used_at: nil, expires_at: expires_at} = row ->
        if DateTime.compare(expires_at, now) == :gt do
          {:ok, row}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp generate_reset_token do
    token = @reset_token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    {token, hash_token(token)}
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  defp reset_token_expiry do
    DateTime.utc_now()
    |> DateTime.add(@reset_token_ttl_seconds, :second)
    |> DateTime.truncate(:second)
  end

  # ---------- API keys ----------

  @doc """
  Lists every API key belonging to `user`, newest first. Includes
  revoked keys — the UI shows them visually distinct so the user
  can tell "this was active then, I revoked it when" without
  mysterious gaps in the list.
  """
  @spec list_api_keys_for(User.t()) :: [ApiKey.t()]
  def list_api_keys_for(%User{id: user_id}) do
    # Secondary sort by `id desc` so two keys inserted within the
    # same second (`inserted_at` is truncated to seconds) still sort
    # deterministically newest-first. Without this, same-second
    # ties are implementation-defined and flaky tests follow.
    Repo.all(
      from k in ApiKey,
        where: k.user_id == ^user_id,
        order_by: [desc: k.inserted_at, desc: k.id]
    )
  end

  @doc """
  Fetches one API key by id, scoped to `user`. Returns `nil` on
  miss (not found or belongs to a different user) — the two cases
  must look the same to the caller to avoid leaking existence.
  """
  @spec get_api_key_for(User.t(), integer()) :: ApiKey.t() | nil
  def get_api_key_for(%User{id: user_id}, key_id) when is_integer(key_id) do
    Repo.get_by(ApiKey, id: key_id, user_id: user_id)
  end

  def get_api_key_for(_, _), do: nil

  @doc """
  Creates a new API key for `user`.

  Returns `{:ok, key, raw_token}` on success. The raw token is the
  only time the plaintext ever surfaces — after this function
  returns the row carries only its SHA-256 hash. The UI shows the
  raw token to the user once with a prominent "copy now, you won't
  see it again" warning.

  Returns `{:error, changeset}` on validation failure (empty name,
  invalid scope).
  """
  @spec create_api_key(User.t(), map()) ::
          {:ok, ApiKey.t(), String.t()} | {:error, Changeset.t()}
  def create_api_key(%User{id: user_id}, params) when is_map(params) do
    {raw_token, hash, prefix} = generate_api_key()

    attrs = %{
      user_id: user_id,
      name: Map.get(params, "name"),
      key_hash: hash,
      key_prefix: prefix,
      permissions: Map.get(params, "permissions", [])
    }

    attrs
    |> ApiKey.create_changeset()
    |> Repo.insert()
    |> case do
      {:ok, key} -> {:ok, key, raw_token}
      {:error, _} = err -> err
    end
  end

  @doc """
  Revokes an API key.

  Idempotent: a already-revoked key is a no-op `{:ok, key}`. A key
  that doesn't belong to `user` returns `{:error, :not_found}` —
  same shape as `get_api_key_for/2` returning `nil`, so the caller
  never has to branch on "is it mine".
  """
  @spec revoke_api_key(User.t(), integer()) ::
          {:ok, ApiKey.t()} | {:error, :not_found}
  def revoke_api_key(%User{} = user, key_id) do
    case get_api_key_for(user, key_id) do
      nil ->
        {:error, :not_found}

      %ApiKey{revoked_at: %DateTime{}} = key ->
        {:ok, key}

      %ApiKey{} = key ->
        key
        |> ApiKey.revoke_changeset(DateTime.utc_now())
        |> Repo.update()
    end
  end

  @doc """
  Resolves a raw token to its owning `{user, api_key}` pair.

  Returns `:error` for a missing / malformed / revoked / unknown
  token. The caller (`RolezinhoWeb.Plugs.ApiAuth`) treats every
  failure identically (401), so this function doesn't bother
  distinguishing them.

  Constant-time-ish: the SHA-256 hash runs even on an unknown
  token, which keeps the "does this key exist" timing signal very
  flat. Not perfect (there's still a Repo roundtrip difference) but
  closer to constant than a short-circuit on prefix mismatch.
  """
  @spec authenticate_api_key(String.t() | nil) ::
          {:ok, User.t(), ApiKey.t()} | :error
  def authenticate_api_key(token) when is_binary(token) and byte_size(token) > 0 do
    hash = hash_token(token)

    query =
      from k in ApiKey,
        where: k.key_hash == ^hash and is_nil(k.revoked_at),
        preload: [:user]

    case Repo.one(query) do
      %ApiKey{user: %User{} = user} = key -> {:ok, user, key}
      _ -> :error
    end
  end

  def authenticate_api_key(_), do: :error

  @doc """
  Stamps `last_used_at` on a key. Called from the API auth plug on
  every successful request so the UI can tell live keys from
  abandoned ones.

  Best-effort: a failed update is logged and swallowed so a flaky
  DB write doesn't take down an otherwise-fine API request.
  """
  @spec touch_api_key(ApiKey.t()) :: :ok
  def touch_api_key(%ApiKey{} = key) do
    key
    |> ApiKey.touch_changeset(DateTime.utc_now())
    |> Repo.update()

    :ok
  rescue
    _ -> :ok
  end

  # Returns `{raw_token, hash, prefix}`. The raw token is
  # `rk_live_<43 url-safe chars>`; the hash is SHA-256 of that; the
  # prefix is the first 16 chars of the raw token.
  defp generate_api_key do
    secret = @api_key_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    raw = @api_key_prefix <> secret
    hash = hash_token(raw)
    prefix = String.slice(raw, 0, @api_key_prefix_display_len)
    {raw, hash, prefix}
  end

  @doc """
  Flags an existing user as a platform admin, keyed by their GitHub login.

  Meant for a remote-console session in production: the shared
  `ADMIN_PASSWORD` is the emergency bypass, this is how you hand out
  durable admin capability. From an IEx prompt:

      iex> Rolezinho.Accounts.make_admin_by_handle("lubien")
      {:ok, %Rolezinho.Accounts.User{admin: true, ...}}

  The lookup is case-insensitive to match how GitHub treats logins (they
  are collision-scoped case-insensitively over there, but stored as-typed
  in this DB, so a callsite from memory should not have to remember the
  exact casing). Returns `{:error, :not_found}` when the user has never
  signed in — accounts here are created on first sign-in, so there is no
  "pre-create by handle" flow.

  Idempotent: calling it on an already-admin user is a no-op that still
  returns `{:ok, user}`.
  """
  @spec make_admin_by_handle(String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def make_admin_by_handle(login) when is_binary(login) do
    trimmed = login |> String.trim() |> String.trim_leading("@")

    if trimmed == "" do
      {:error, :not_found}
    else
      case get_by_github_login(trimmed) do
        %User{admin: true} = user ->
          {:ok, user}

        %User{} = user ->
          user
          |> Ecto.Changeset.change(admin: true)
          |> Repo.update()

        nil ->
          {:error, :not_found}
      end
    end
  end

  # Case-insensitive lookup on `github_login`. Two GitHub users cannot share
  # a login (case-insensitive over on their end), so this can safely return
  # at most one row.
  defp get_by_github_login(login) when is_binary(login) do
    import Ecto.Query, only: [from: 2]

    Repo.one(
      from u in User,
        where: fragment("lower(?) = ?", u.github_login, ^String.downcase(login)),
        limit: 1
    )
  end

  # Accepts an integer (already parsed) or a string (as the OAuth adapter
  # sometimes hands it back). Anything else collapses to nil so the caller
  # returns a proper validation error rather than crashing.
  defp to_integer(id) when is_integer(id), do: id

  defp to_integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_integer(_), do: nil
end
