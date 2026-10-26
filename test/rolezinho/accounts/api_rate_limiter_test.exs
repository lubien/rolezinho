defmodule Rolezinho.Accounts.ApiRateLimiterTest do
  @moduledoc """
  Per-key rate limiter for the REST API. Two independent windows,
  both must clear:

    * Minute window: 60 req, resets at every UTC minute boundary.
    * Day window: 10 000 req, resets at UTC midnight.
  """
  use ExUnit.Case, async: false

  alias Rolezinho.Accounts.ApiRateLimiter

  @minute_cap 60
  @day_cap 10_000

  setup do
    :ok = ApiRateLimiter.init()
    :ok = ApiRateLimiter.reset!()
    :ok
  end

  test "first hit for a key is :ok" do
    assert :ok = ApiRateLimiter.check(42)
  end

  test "up to the minute cap is allowed, then denied with retry-after" do
    for _ <- 1..@minute_cap, do: assert(:ok = ApiRateLimiter.check(42))

    assert {:error, :rate_limited, retry_after} = ApiRateLimiter.check(42)
    assert retry_after > 0
    assert retry_after <= 60
  end

  test "distinct keys are isolated" do
    for _ <- 1..@minute_cap, do: assert(:ok = ApiRateLimiter.check(1))
    assert {:error, :rate_limited, _} = ApiRateLimiter.check(1)

    # Different key — fresh bucket.
    assert :ok = ApiRateLimiter.check(2)
  end

  test "remaining/1 reports the remaining headroom in both windows" do
    assert {60, 10_000} = ApiRateLimiter.remaining(99)

    for _ <- 1..5, do: assert(:ok = ApiRateLimiter.check(99))

    assert {55, 9_995} = ApiRateLimiter.remaining(99)
  end

  test "remaining/1 reports 0 for a rate-limited key" do
    for _ <- 1..@minute_cap, do: assert(:ok = ApiRateLimiter.check(7))

    assert {0, _} = ApiRateLimiter.remaining(7)
  end

  test "reset!/0 wipes every bucket" do
    for _ <- 1..@minute_cap, do: assert(:ok = ApiRateLimiter.check(1))
    assert {:error, :rate_limited, _} = ApiRateLimiter.check(1)

    ApiRateLimiter.reset!()

    assert :ok = ApiRateLimiter.check(1)
  end
end
