# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :rolezinho,
  ecto_repos: [Rolezinho.Repo],
  generators: [timestamp_type: :utc_datetime],
  admin_password: "admin"

# Defense in depth: Phoenix filters these keys out of logged request
# params so a request body that happens to be logged (via a crash,
# a plug that logs, a dev `IO.inspect(conn)`) never surfaces a
# secret in plaintext. Covers the auth code paths (password, reset
# tokens) and the 2026-10 REST API tokens.
config :phoenix,
       :filter_parameters,
       [
         "password",
         "password_hash",
         "current_password",
         "token",
         "api_key",
         "authorization",
         "encoded"
       ]

# Configure the endpoint
config :rolezinho, RolezinhoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RolezinhoWeb.ErrorHTML, json: RolezinhoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Rolezinho.PubSub,
  live_view: [signing_salt: "2E1maID6"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# GitHub OAuth (ADR-0002). Ueberauth registers a plug pipeline at
# `/auth/:provider`; we only expose `github`. Client id and secret land in
# `config/runtime.exs` from env vars — the compile-time entry here just says
# "the GitHub strategy exists and asks only for the email scope", which is all
# ueberauth needs to plan its routes.
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "read:user user:email"]}
  ]

config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: {:system, "GITHUB_CLIENT_ID"},
  client_secret: {:system, "GITHUB_CLIENT_SECRET"}

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :rolezinho, Rolezinho.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  rolezinho: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  storybook: [
    args:
      ~w(js/storybook.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  rolezinho: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
