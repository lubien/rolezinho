defmodule Rolezinho.Accounts.ApiRateLimiter do
  @moduledoc """
  Per-key rate limiter for the REST API.

  Two independent windows, both must clear:

    * **Per minute** \u2014 60 req, resets at the top of every UTC minute.
    * **Per day** \u2014 10_000 req, resets at UTC midnight.

  Same ETS-backed fixed-window shape as `ResetRateLimiter`: one row
  per `(key_id, window_kind)` carrying a count and an expiry
  timestamp. First hit in a window inserts the row with count 1;
  subsequent hits increment in place; stale rows are naturally
  overwritten.

  The window is fixed, not sliding. That's slightly looser than a
  sliding window (a burst at the end of one window + the start of
  the next can briefly double the effective rate) but much cheaper
  to compute and plenty for abuse control. A real API consumer
  pacing their traffic never notices.

  Returns, when a key is rate-limited, the number of seconds until
  the smaller of the two windows resets \u2014 that's what the plug
  sends as `Retry-After`.
  """

  @table :rolezinho_api_rate_limits

  @minute_window_seconds 60
  @minute_max 60

  @day_window_seconds 86_400
  @day_max 10_000

  @doc "Creates the underlying ETS table. Idempotent."
  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true,
          decentralized_counters: true
        ])

        :ok

      _tid ->
        :ok
    end
  end

  @doc """
  Checks (and increments) both windows for `key_id`.

  Returns `:ok` under the cap, `{:error, :rate_limited, retry_after_seconds}`
  when either window is at or past the cap. `retry_after_seconds`
  is the time until the earliest window resets, so the caller
  (`RolezinhoWeb.Plugs.ApiAuth`) can set `Retry-After` honestly.
  """
  @spec check(integer()) :: :ok | {:error, :rate_limited, non_neg_integer()}
  def check(key_id) when is_integer(key_id) do
    with :ok <- hit({:min, key_id}, @minute_max, @minute_window_seconds),
         :ok <- hit({:day, key_id}, @day_max, @day_window_seconds) do
      :ok
    end
  end

  @doc """
  Returns the remaining-request counts (`{minute, day}`) for `key_id`
  without consuming a hit. Used by the plug to populate the
  `X-RateLimit-Remaining-*` response headers.
  """
  @spec remaining(integer()) :: {non_neg_integer(), non_neg_integer()}
  def remaining(key_id) when is_integer(key_id) do
    {remaining_for({:min, key_id}, @minute_max), remaining_for({:day, key_id}, @day_max)}
  end

  @doc "Test helper: wipes every bucket. Not used at runtime."
  @spec reset!() :: :ok
  def reset! do
    _ = init()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp hit(key, max, window_seconds) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, _count, expires_at}] when expires_at <= now ->
        :ets.insert(@table, {key, 1, now + window_seconds})
        :ok

      [{^key, count, _expires_at}] when count < max ->
        :ets.update_counter(@table, key, {2, 1})
        :ok

      [{^key, count, expires_at}] when count >= max ->
        {:error, :rate_limited, max(expires_at - now, 1)}

      [] ->
        :ets.insert(@table, {key, 1, now + window_seconds})
        :ok
    end
  end

  defp remaining_for(key, max) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, _count, expires_at}] when expires_at <= now -> max
      [{^key, count, _expires_at}] when count >= max -> 0
      [{^key, count, _expires_at}] -> max - count
      [] -> max
    end
  end
end
