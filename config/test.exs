import Config

config :rolezinho,
  admin_password: "test-admin-password"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# Jobs are asserted on, not run, unless a test drains a queue explicitly.
config :rolezinho, Oban, testing: :manual

config :rolezinho, :pusher, Rolezinho.Notifications.TestPusher

config :web_push_elixir,
  vapid_public_key:
    "BIlLWlxXcTKR5JvQTO07d5sq341XRvhgpGz2Qqi3NhHD0RjSKoi4mR5qHC-fqVuXsMI0RsObG_-d3nz6UEfuylg",
  vapid_private_key: "k7ehG-yMHBjEQK-uFFPBZlRdTAncEob2YvioQVPhDI8",
  vapid_subject: "mailto:test@rolezinho.local"

config :rolezinho, Rolezinho.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "rolezinho_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :rolezinho, RolezinhoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "BGpZnFz41Z8mutIYQVNmoSNFF3U/8/l20Wut3/IN19230o11ChP9h03di98f+QNj",
  server: false

# In test we don't send emails
config :rolezinho, Rolezinho.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
