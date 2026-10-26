defmodule RolezinhoWeb.Router do
  use RolezinhoWeb, :router

  import RolezinhoWeb.Plugs.Admin
  import RolezinhoWeb.Plugs.ContentSecurityPolicy
  import RolezinhoWeb.Plugs.Participant
  import RolezinhoWeb.Plugs.User

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RolezinhoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_content_security_policy
    plug :fetch_admin
    plug :fetch_participant
    plug :fetch_current_user
    plug RolezinhoWeb.Plugs.AgentDiscovery
  end

  pipeline :admin_required do
    plug :require_admin
  end

  # REST API pipeline (2026-10). JSON-only, bearer-auth via
  # `RolezinhoWeb.Plugs.ApiAuth`. Skips the browser pipeline
  # entirely — no session, no CSP, no admin fetch, no participant
  # fetch. The auth plug populates `:current_user` and
  # `:current_api_key` from the bearer token.
  pipeline :api do
    plug :accepts, ["json"]
    plug RolezinhoWeb.Plugs.ApiResponseHeaders
    plug RolezinhoWeb.Plugs.ApiAuth
  end

  ## Public routes
  scope "/", RolezinhoWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [
        {RolezinhoWeb.Plugs.Admin, :fetch},
        {RolezinhoWeb.Plugs.Participant, :fetch},
        {RolezinhoWeb.Plugs.User, :fetch}
      ] do
      live "/", HomeLive, :index
      live "/me", SettingsLive, :show
      live "/me/chaves", ApiKeysLive, :index
      live "/me/chaves/nova", ApiKeysLive, :new
      live "/r/:slug", EventLive, :show
      live "/r/:slug/convite", InviteLive, :show
      live "/r/:slug/pagamento", PaymentLive, :show
      live "/criar", EventNewLive, :new
      live "/g/criar", GroupNewLive, :new
      live "/g/:slug", GroupLive, :show
      live "/entrar", SignInLive, :show
      live "/entrar/esqueci", ForgotPasswordLive, :show
      live "/entrar/nova-senha/:token", ResetPasswordLive, :show
      live "/atualizar", UpdateFromChatLive, :pick
      live "/atualizar/:slug", UpdateFromChatLive, :diff

      # Edit surfaces: reachable by admin OR by the resource's own
      # owner. The paths keep the `/admin/` prefix for bookmark
      # backward-compat, but the pipeline gate is off — each LiveView
      # does its own `Policy.can_edit?/2` (event) or
      # `Group.editable_by?/4` (group) check in `mount/3`, and each
      # handler that mutates admin-only bits (owner reassignment,
      # group visibility, deletes) still calls `require_admin!/1`.
      live "/admin/r/:slug/edit", EventEditLive, :edit
      live "/admin/r/:slug/formulario", FormConfigLive, :show
      live "/admin/g/:slug/edit", GroupEditLive, :edit
    end

    get "/r/txt/:slug", RawController, :show
    get "/r/:slug/calendar", CalendarController, :show
    get "/atualizar.md", UpdateFromChatController, :docs
    get "/api.md", DocsController, :api
    get "/agents.md", DocsController, :agents
    get "/llms.txt", DocsController, :llms
    post "/r/:slug/unlock", EventUnlockController, :unlock
    post "/r/:slug/join", JoinController, :create
    post "/criar", EventCreateController, :create
    post "/g/criar", GroupCreateController, :create
    post "/g/:slug/unlock", GroupUnlockController, :unlock

    # Local (username + password) auth. GitHub OAuth stays alongside
    # at `/auth/github` — both paths land on the same session.
    post "/entrar/senha", SessionController, :create
    post "/entrar/registrar", SessionController, :register
    post "/entrar/esqueci", PasswordResetController, :create
    post "/entrar/nova-senha/:token", PasswordResetController, :update

    get "/admin/login", AdminSessionController, :new
    post "/admin/login", AdminSessionController, :create
    delete "/admin/logout", AdminSessionController, :delete

    # GitHub OAuth (ADR-0002). The ueberauth plug takes over on both routes;
    # the AuthController is only reached on success/failure of the callback
    # (and on the request action when the plug pipeline could not initiate).
    get "/auth/:provider", AuthController, :request
    get "/auth/:provider/callback", AuthController, :callback
    delete "/auth/logout", AuthController, :delete
  end

  ## REST API (2026-10)
  scope "/api/v1", RolezinhoWeb.Api.V1 do
    pipe_through :api

    get "/auth/whoami", AuthController, :whoami

    get "/events", EventController, :index
    get "/events/:slug", EventController, :show
    post "/events", EventController, :create
    patch "/events/:slug", EventController, :update
    delete "/events/:slug", EventController, :delete

    get "/events/:slug/participants", ParticipantController, :index
    post "/events/:slug/participants", ParticipantController, :create
    patch "/events/:slug/participants/:index", ParticipantController, :update
    delete "/events/:slug/participants/:index", ParticipantController, :delete
    post "/events/:slug/participants/:index/promote", ParticipantController, :promote

    get "/groups", GroupController, :index
    get "/groups/:slug", GroupController, :show
    post "/groups", GroupController, :create
    patch "/groups/:slug", GroupController, :update
    delete "/groups/:slug", GroupController, :delete
  end

  ## Admin-only routes — the ADMIN dashboard proper. Edit surfaces
  ## used to live here too, but moved to the public scope with per-
  ## LiveView policy checks so a role/group owner can edit their own
  ## thing without also holding the shared admin password.
  scope "/admin", RolezinhoWeb do
    pipe_through [:browser, :admin_required]

    live_session :admin,
      on_mount: [
        {RolezinhoWeb.Plugs.Admin, :require_admin},
        {RolezinhoWeb.Plugs.User, :fetch}
      ] do
      live "/", AdminHomeLive, :index
    end
  end

  # Enable LiveDashboard, Swoosh mailbox preview and the component catalog in
  # development. Storybook is a development tool: it is not mounted in
  # production, where it would only add public surface.
  if Application.compile_env(:rolezinho, :dev_routes) do
    import Phoenix.LiveDashboard.Router
    import PhoenixStorybook.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RolezinhoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/" do
      storybook_assets()
    end

    scope "/" do
      pipe_through :browser

      live_storybook("/storybook", backend_module: RolezinhoWeb.Storybook)
    end
  end
end
