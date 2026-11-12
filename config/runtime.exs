import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/rolezinho start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :rolezinho, RolezinhoWeb.Endpoint, server: true
end

config :rolezinho, RolezinhoWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if admin_password = System.get_env("ADMIN_PASSWORD") do
  config :rolezinho, :admin_password, admin_password
end

# GitHub OAuth (ADR-0002). ueberauth_github reads its client id and secret
# from application env at runtime, so we plug them in here from environment
# variables. In dev this is optional — someone running the app without a
# GitHub app configured just cannot use the /criar path unless they log in as
# admin. In production it is mandatory: see the raise below.
if client_id = System.get_env("GITHUB_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.Github.OAuth, client_id: client_id
end

if client_secret = System.get_env("GITHUB_CLIENT_SECRET") do
  config :ueberauth, Ueberauth.Strategy.Github.OAuth, client_secret: client_secret
end

if config_env() == :prod do
  # config.exs ships a development default, so without this a deploy that forgot
  # the variable would come up with the admin password literally set to "admin"
  # — working, and wide open. Fail at boot instead, the same way a missing
  # SECRET_KEY_BASE does.
  System.get_env("ADMIN_PASSWORD") ||
    raise """
    environment variable ADMIN_PASSWORD is missing.
    It guards every admin surface — the app refuses to boot without it.
    """

  # Same treatment for the GitHub OAuth credentials. Missing them in prod
  # means creation is broken for anyone who isn't admin — an easy silent
  # regression to ship, so we fail loudly instead.
  System.get_env("GITHUB_CLIENT_ID") ||
    raise """
    environment variable GITHUB_CLIENT_ID is missing.
    It's needed for the sign-in flow that gates /criar and /g/criar (ADR-0002).
    """

  System.get_env("GITHUB_CLIENT_SECRET") ||
    raise """
    environment variable GITHUB_CLIENT_SECRET is missing.
    It's needed for the sign-in flow that gates /criar and /g/criar (ADR-0002).
    """

  # Web Push (group notifications). The private key signs every push request;
  # a deploy without it would silently send nothing, so fail at boot.
  # Generate a pair with `mix generate.vapid.keys`.
  config :web_push_elixir,
    vapid_public_key:
      System.get_env("VAPID_PUBLIC_KEY") ||
        raise("environment variable VAPID_PUBLIC_KEY is missing (Web Push)."),
    vapid_private_key:
      System.get_env("VAPID_PRIVATE_KEY") ||
        raise("environment variable VAPID_PRIVATE_KEY is missing (Web Push)."),
    vapid_subject:
      System.get_env("VAPID_SUBJECT") ||
        raise("environment variable VAPID_SUBJECT is missing (Web Push, e.g. mailto:you@x).")

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :rolezinho, Rolezinho.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :rolezinho, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :rolezinho, RolezinhoWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :rolezinho, RolezinhoWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :rolezinho, RolezinhoWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # Password-reset emails (2026-09 ADR-0002 amendment) go through
  # `Rolezinho.Mailer`. The default compile-time adapter is
  # `Swoosh.Adapters.Local` — fine for dev, useless in prod. Set the
  # `RESEND_API_KEY` env var and this block flips the adapter to
  # Resend at boot; leaving it unset keeps prod on the Local adapter
  # (no crash, no email delivered).
  #
  # Resend is a good starter transactional provider because the setup
  # is a single API key plus a verified sending domain. The API
  # client Req is already loaded (see `config/prod.exs`).
  #
  # Env vars:
  #
  #   * `RESEND_API_KEY` — required to enable the adapter.
  #   * `MAILER_FROM` — optional. The From address on outgoing mail;
  #     must belong to a domain you've verified in the Resend
  #     dashboard. Defaults to `no-reply@rolezinho.lubien.dev`.
  if resend_key = System.get_env("RESEND_API_KEY") do
    config :rolezinho, Rolezinho.Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: resend_key
  end

  if from = System.get_env("MAILER_FROM") do
    config :rolezinho, :mailer_from, from
  end
end
