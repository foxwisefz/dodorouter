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
    plug :accepts, ["json"]
    plug DodoRouterWeb.Plugs.ApiAuth
  end

  # LLM Proxy API - Router-specific endpoint
  scope "/r/:router_slug/v1", DodoRouterWeb do
    pipe_through :proxy_api

    get "/models", ProxyController, :models
    post "/chat/completions", ProxyController, :create
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
        {DodoRouterWeb.NavHooks, :load_routers}
      ] do
      live "/routers", RouterLive.Index, :index
      live "/routers/new", RouterLive.Index, :new
      live "/routers/:id", RouterLive.Show, :show
      live "/routers/:id/edit", RouterLive.Show, :edit
      live "/routers/:id/routing", RouterLive.Show, :routing

      live "/providers", ProvidersLive.Index, :index

      live "/logs", LogLive.Index, :index
      live "/logs/:id", LogLive.Show, :show

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
