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

  # Audit runs before auth on purpose: a call refused for a bad or unscoped
  # token is exactly the one worth having a record of, and a plug that only
  # sees authenticated requests cannot write it.
  pipeline :agent_api do
    plug :accepts, ["json"]
    plug DodoRouterWeb.Plugs.AgentAudit, interface: "rest"
    plug DodoRouterWeb.Plugs.AgentAuth
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

  # Agent API - lets a coding agent working on a product measure quality vs
  # price for that product's own traffic.
  #
  # Deliberately NOT :proxy_api. A router's proxy key exists to send traffic;
  # these endpoints read traffic back, and giving one credential both turns a
  # leaked .env from "someone burns my tokens" into "someone has every prompt
  # my product ever sent". Agent tokens are separately issued, scoped and
  # revocable, and every call here is recorded.
  #
  # `/agent` is the discovery endpoint; it describes everything below it.
  # Static eval paths precede `/evals/:id` so "targets" isn't read as an id.
  scope "/r/:router_slug", DodoRouterWeb do
    pipe_through :agent_api

    get "/agent", EvalsController, :guide

    get "/logs", LogsController, :index
    get "/logs/:id", LogsController, :show

    get "/evals/targets", EvalsController, :targets
    get "/evals", EvalsController, :index
    post "/evals", EvalsController, :create
    get "/evals/:id", EvalsController, :show
    post "/evals/:id/run", EvalsController, :run
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
end
