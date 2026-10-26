defmodule Rolezinho.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Password-reset rate limiter: an ETS-backed fixed-window counter
    # shared across all requesting processes. Named + public, so a
    # supervision restart during code reload doesn't need to hand the
    # tid around. Created before the endpoint so the first request
    # hitting `/entrar/esqueci` after boot never races the table.
    :ok = Rolezinho.Accounts.ResetRateLimiter.init()

    # Same shape for the REST API's per-key rate limiter. Two
    # windows (minute + day), both consulted on every authenticated
    # request. See the module docs for the tuning.
    :ok = Rolezinho.Accounts.ApiRateLimiter.init()

    children = [
      RolezinhoWeb.Telemetry,
      Rolezinho.Repo,
      {DNSCluster, query: Application.get_env(:rolezinho, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Rolezinho.PubSub},
      # Start a worker by calling: Rolezinho.Worker.start_link(arg)
      # {Rolezinho.Worker, arg},
      # Start to serve requests, typically the last entry
      RolezinhoWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Rolezinho.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RolezinhoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
