defmodule DodoRouterWeb.Router do
  use DodoRouterWeb, :router

  import DodoRouterWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DodoRouterWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :proxy_api do
    plug DodoRouterWeb.Plugs.ApiAuth
  end

  # The authorization endpoint runs OUR login and consent UI, so it needs a
  # session — but deliberately not the generic :browser pipeline. attesto warns
  # about exactly this: CSRF protection would reject the externally-submitted
  # OAuth POSTs that are supposed to arrive without our token.
  # attesto's controllers read their config from conn.private, so every one of
  # its routes needs this — including the unauthenticated discovery documents.
  pipeline :attesto_config do
    plug DodoRouterWeb.Plugs.AttestoConfig
  end

  pipeline :oauth_interactive do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DodoRouterWeb.Layouts, :root}
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  # The only way in. Bearer agent tokens were the interim credential while the
  # decision was open (dodo_router-5m5.5); once Claude Code completed the OAuth
  # flow end to end they were deleted rather than kept as a second door — one
  # credential mechanism means one place where scope and revocation are decided.
  #
  # `Authenticate` rather than `ProtectResource`: the latter also enforces a
  # route-level scope, and ours are per-tool — one scope guarding the whole
  # endpoint would be too strict for tools/list and meaningless for tools/call.
  # Tools.call/3 stays the single place scope is enforced.
  pipeline :mcp_api do
    plug :accepts, ["json"]
    plug DodoRouterWeb.Plugs.AgentAudit, interface: "mcp"

    plug AttestoMCP.Plug.Authenticate,
      config: &DodoRouter.AuthZ.resource_config/0,
      resource_path: "/mcp"

    plug DodoRouterWeb.Plugs.OAuthPrincipal
  end

  # LLM Proxy API - Router-specific endpoint
  scope "/r/:router_slug/v1", DodoRouterWeb do
    pipe_through :proxy_api

    get "/models", ProxyController, :models
    post "/chat/completions", ProxyController, :create
    post "/messages", AnthropicProxyController, :create
    post "/messages/count_tokens", AnthropicProxyController, :count_tokens
    post "/responses", ResponsesProxyController, :create
  end

  # Recordings API - start/stop server-side request capture
  scope "/r/:router_slug", DodoRouterWeb do
    pipe_through :proxy_api

    post "/recordings/start", RecordingsController, :start
    get "/recordings/active", RecordingsController, :active
    post "/recordings/active/stop", RecordingsController, :stop
  end

  # MCP endpoint, revision 2026-07-28. Router-unscoped: the protocol is
  # stateless and every tool takes its router as an argument, resolved against
  # what the token reaches.
  scope "/", DodoRouterWeb do
    pipe_through :mcp_api

    post "/mcp", MCPController, :create
    # The 2026-07-28 revision removed the GET stream and the DELETE session
    # teardown; answering 405 tells an older client that rather than 404,
    # which it would read as "no MCP here at all".
    get "/mcp", MCPController, :not_allowed
    delete "/mcp", MCPController, :not_allowed
  end

  # Legacy endpoint (backwards compatibility)
  scope "/v1", DodoRouterWeb do
    pipe_through :proxy_api

    post "/chat/completions", ProxyController, :create_legacy
  end

  # Health check (no auth, no session)
  scope "/", DodoRouterWeb do
    pipe_through :api
    get "/health", HealthController, :index
    get "/api/version", VersionController, :index
  end

  # Public routes
  scope "/", DodoRouterWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/terms", TermsController, :index
  end

  # Dashboard (requires auth)
  scope "/", DodoRouterWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated,
      on_mount: [
        {DodoRouterWeb.UserAuth, :ensure_authenticated},
        {DodoRouterWeb.NavHooks, :load_routers},
        {DodoRouterWeb.NavHooks, :load_providers}
      ] do
      live "/routers", RouterLive.Index, :index
      live "/routers/new", RouterLive.Index, :new
      live "/routers/:id", RouterLive.Show, :show
      live "/routers/:id/edit", RouterLive.Show, :edit
      live "/routers/:id/routing", RouterLive.Show, :routing
      live "/routers/:id/routing/:step_id/edit", RouterLive.Show, :edit_step

      live "/providers", ProvidersLive.Index, :index
      live "/api-keys", ApiKeysLive.Index, :index
      live "/agent-activity", AgentActivityLive.Index, :index

      live "/logs", LogLive.Index, :index
      live "/logs/:id", LogLive.Show, :show
      live "/logs/:id/replay", LogLive.Replay, :show
      live "/logs/:id/evals/new", EvalLive.New, :new
      live "/evals", EvalLive.Index, :index
      live "/evals/:id", EvalLive.Show, :show

      live "/routers/:router_id/sessions", SessionLive.Index, :index
      live "/routers/:router_id/sessions/:session_id", SessionLive.Show, :show

      live "/routers/:router_id/recordings", RecordingLive.Index, :index
      live "/routers/:router_id/recordings/:id", RecordingLive.Show, :show
      live "/routers/:router_id/recordings/:recording_id/evals/new", EvalLive.New, :from_recording

      live "/dashboard", DashboardLive, :index
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:dodo_router, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DodoRouterWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", DodoRouterWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", DodoRouterWeb do
    pipe_through [:browser, :require_authenticated_user]

    put "/preferences", PreferencesController, :update

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/", DodoRouterWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  use AttestoPhoenix.Router

  # registration: true mounts RFC 7591 dynamic client registration, which is
  # what lets an assistant connect without being pre-registered by hand.
  scope "/" do
    attesto_routes(
      registration: true,
      # Mounts the RFC 9728 §3.1 resource-specific document at
      # /.well-known/oauth-protected-resource/mcp — the exact URL the /mcp 401
      # challenge advertises. Without it the challenge points at a 404 and a
      # client can discover nothing.
      protected_resource_paths: ["/mcp"],
      pipeline: :attesto_config,
      # A route-class override is the complete ordered list; attesto does not
      # prepend the :pipeline default, so :attesto_config is repeated here.
      route_pipelines: [interactive: [:attesto_config, :oauth_interactive]]
    )
  end

  # Our own consent screen, which the :consent callback halts into and which
  # re-enters /oauth/authorize carrying a single-use grant.
  scope "/oauth", DodoRouterWeb do
    pipe_through :oauth_interactive

    get "/consent", OAuthConsentController, :show
    post "/consent", OAuthConsentController, :create
  end
end
