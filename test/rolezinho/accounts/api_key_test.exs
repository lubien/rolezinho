defmodule Rolezinho.Accounts.ApiKeyTest do
  @moduledoc """
  Context + schema coverage for API keys.

    * Create / list / revoke roundtrip.
    * Only the SHA-256 hash lands in the DB (never the raw token).
    * `authenticate_api_key/1` resolves a valid token to the owning
      user; refuses revoked / unknown / malformed input.
    * Permission validation rejects unknown scopes.
    * `has_scope?/2` enforces the revoked = no-scope invariant.
  """
  use Rolezinho.DataCase, async: false

  alias Rolezinho.Accounts
  alias Rolezinho.Accounts.ApiKey

  defp register do
    n = System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(4, "0")

    {:ok, user} =
      Accounts.register_user(%{
        "username" => "apiuser#{n}",
        "password" => "supersecret"
      })

    user
  end

  describe "create_api_key/2" do
    test "returns {:ok, key, raw_token} and stores only the hash" do
      user = register()

      assert {:ok, %ApiKey{} = key, raw_token} =
               Accounts.create_api_key(user, %{
                 "name" => "bot-whatsapp",
                 "permissions" => ["events:read", "participants:write"]
               })

      assert key.user_id == user.id
      assert key.name == "bot-whatsapp"
      # Permissions sorted + deduped.
      assert key.permissions == ["events:read", "participants:write"]
      # Raw token has the expected prefix shape.
      assert String.starts_with?(raw_token, "rk_live_")
      # Hash on the row matches the SHA-256 of the raw token.
      assert key.key_hash == :crypto.hash(:sha256, raw_token)
      # Prefix is the first 16 chars, usable for display.
      assert key.key_prefix == String.slice(raw_token, 0, 16)
    end

    test "rejects a blank name" do
      user = register()

      assert {:error, changeset} =
               Accounts.create_api_key(user, %{"name" => "   ", "permissions" => ["events:read"]})

      assert "obrigatório" in errors_on(changeset).name
    end

    test "rejects unknown scopes" do
      user = register()

      assert {:error, changeset} =
               Accounts.create_api_key(user, %{
                 "name" => "oops",
                 "permissions" => ["events:read", "events:yolo"]
               })

      assert %{permissions: [msg]} = errors_on(changeset)
      assert msg =~ "events:yolo"
    end

    test "deduplicates scopes" do
      user = register()

      assert {:ok, %ApiKey{permissions: perms}, _} =
               Accounts.create_api_key(user, %{
                 "name" => "dedup",
                 "permissions" => ["events:read", "events:read", "events:write"]
               })

      assert perms == ["events:read", "events:write"]
    end
  end

  describe "authenticate_api_key/1" do
    test "resolves a valid token to its user" do
      user = register()
      {:ok, _key, raw} = Accounts.create_api_key(user, %{"name" => "k", "permissions" => []})

      assert {:ok, resolved_user, %ApiKey{}} = Accounts.authenticate_api_key(raw)
      assert resolved_user.id == user.id
    end

    test "refuses a revoked key" do
      user = register()
      {:ok, key, raw} = Accounts.create_api_key(user, %{"name" => "k", "permissions" => []})
      {:ok, _} = Accounts.revoke_api_key(user, key.id)

      assert :error = Accounts.authenticate_api_key(raw)
    end

    test "refuses an unknown token (constant-time-ish — still runs the hash)" do
      assert :error = Accounts.authenticate_api_key("rk_live_definitely-not-real")
    end

    test "refuses nil / empty / non-binary input" do
      assert :error = Accounts.authenticate_api_key(nil)
      assert :error = Accounts.authenticate_api_key("")
      assert :error = Accounts.authenticate_api_key(123)
    end
  end

  describe "revoke_api_key/2" do
    test "flips revoked_at and makes the key unauthenticatable" do
      user = register()
      {:ok, key, raw} = Accounts.create_api_key(user, %{"name" => "k", "permissions" => []})

      assert {:ok, revoked} = Accounts.revoke_api_key(user, key.id)
      assert %DateTime{} = revoked.revoked_at

      assert :error = Accounts.authenticate_api_key(raw)
    end

    test "is idempotent — revoking an already-revoked key is a no-op {:ok, key}" do
      user = register()
      {:ok, key, _raw} = Accounts.create_api_key(user, %{"name" => "k", "permissions" => []})
      {:ok, revoked} = Accounts.revoke_api_key(user, key.id)

      assert {:ok, same} = Accounts.revoke_api_key(user, key.id)
      assert same.revoked_at == revoked.revoked_at
    end

    test "returns :not_found for a key belonging to another user" do
      owner = register()
      stranger = register()

      {:ok, key, _} = Accounts.create_api_key(owner, %{"name" => "mine", "permissions" => []})

      assert {:error, :not_found} = Accounts.revoke_api_key(stranger, key.id)
    end
  end

  describe "list_api_keys_for/1" do
    test "returns the user's keys newest-first, including revoked" do
      user = register()
      {:ok, k1, _} = Accounts.create_api_key(user, %{"name" => "old", "permissions" => []})
      Process.sleep(10)
      {:ok, k2, _} = Accounts.create_api_key(user, %{"name" => "new", "permissions" => []})
      {:ok, _} = Accounts.revoke_api_key(user, k1.id)

      list = Accounts.list_api_keys_for(user)
      assert [first, second] = list
      assert first.id == k2.id
      assert second.id == k1.id
      # Revoked key is still in the list.
      assert %DateTime{} = second.revoked_at
    end

    test "scoped to the owning user — never returns another user's keys" do
      owner = register()
      stranger = register()

      {:ok, _, _} = Accounts.create_api_key(owner, %{"name" => "mine", "permissions" => []})

      assert Accounts.list_api_keys_for(stranger) == []
    end
  end

  describe "has_scope?/2" do
    test "returns true when the scope is present and the key is active" do
      key = %ApiKey{permissions: ["events:read", "groups:read"], revoked_at: nil}
      assert ApiKey.has_scope?(key, "events:read")
      assert ApiKey.has_scope?(key, "groups:read")
      refute ApiKey.has_scope?(key, "events:write")
    end

    test "returns false for every scope when the key is revoked" do
      key = %ApiKey{permissions: ["events:read"], revoked_at: DateTime.utc_now()}
      refute ApiKey.has_scope?(key, "events:read")
    end
  end
end
