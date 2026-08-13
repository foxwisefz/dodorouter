# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dodo_router, AttestoPhoenix.Config,
  issuer: System.get_env("ATTESTO_ISSUER") || "https://localhost",
  # RFC 8707 resource identifier: the canonical URI of the MCP endpoint. Tokens
  # are minted with this as `aud` and the resource server refuses any token
  # minted for something else, so a token stolen from another service of ours
  # cannot be replayed here.
  audience: System.get_env("ATTESTO_AUDIENCE") || "https://localhost/mcp",
  keystore: DodoRouter.AuthZ.Keystore,
  repo: DodoRouter.Repo,
  principal_kinds: {DodoRouter.AuthZ, :principal_kinds},
  load_client: {DodoRouter.AuthZ.ClientStore, :load_client},
  verify_client_secret: {DodoRouter.AuthZ.ClientStore, :verify_client_secret},
  load_principal: {DodoRouter.AuthZ.PrincipalStore, :load_principal},
  build_principal: {DodoRouter.AuthZ.PrincipalStore, :build_principal},
  authorize_scope: {DodoRouter.AuthZ.ScopePolicy, :authorize_scope},
  authenticate_resource_owner: {DodoRouter.AuthZ.ConsentPolicy, :authenticate_resource_owner},
  consent: {DodoRouter.AuthZ.ConsentPolicy, :consent},
  on_event: {DodoRouter.AuthZ.EventSink, :on_event},
  oauth_path_prefix: "/oauth",
  # The agent-surface scopes are the same names bearer agent tokens use, so a
  # scope means one thing regardless of which credential carried it.
  scopes_supported: [
    "openid",
    "offline_access",
    "logs:read",
    "logs:read_bodies",
    "evals:read",
    "evals:write"
  ],
  code_store: AttestoPhoenix.Store.EctoCodeStore,
  refresh_store: AttestoPhoenix.Store.EctoRefreshStore,
  nonce_store: AttestoPhoenix.Store.EctoNonceStore,
  replay_check: {AttestoPhoenix.Store.EctoReplayCheck, :check_and_record},
  par_store: AttestoPhoenix.Store.EctoPARStore,
  consent_grant_store: AttestoPhoenix.Store.EctoConsentGrantStore,
  sweep_interval_ms: 60000,
  dpop_enabled: true,
  dpop_nonce_required: false,
  require_https: true,
  # A desktop assistant cannot be pre-registered — nobody knows its loopback
  # callback port until it starts — so RFC 7591 self-registration is the only
  # way it can connect at all. Registering grants nothing on its own: a client
  # gets no token until a signed-in user completes consent.
  registration_enabled: true,
  register_client: {DodoRouter.AuthZ.RegistrationStore, :register_client},
  unregister_client: {DodoRouter.AuthZ.RegistrationStore, :unregister_client},
  client_registration_access_token_hash:
    {DodoRouter.AuthZ.RegistrationStore, :client_registration_access_token_hash},
  client_redirect_uris: {DodoRouter.AuthZ.ClientStore, :client_redirect_uris},
  client_public?: {DodoRouter.AuthZ.ClientStore, :client_public?},
  client_native?: {DodoRouter.AuthZ.ClientStore, :client_native?},
  client_grant_types: {DodoRouter.AuthZ.ClientStore, :client_grant_types},
  client_requires_dpop?: {DodoRouter.AuthZ.ClientStore, :client_requires_dpop?},
  client_requires_mtls?: {DodoRouter.AuthZ.ClientStore, :client_requires_mtls?},
  client_id: {DodoRouter.AuthZ.ClientStore, :client_id}

config :dodo_router, :scopes,
  user: [
    default: true,
    module: DodoRouter.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: DodoRouter.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :dodo_router,
  ecto_repos: [DodoRouter.Repo],
  generators: [timestamp_type: :utc_datetime]

# Appended to every cookie name we set. Empty everywhere but a dev workspace,
# where it keeps two branches on localhost from overwriting each other's login
# (see config/dev.exs and scripts/dev-workspace.sh).
config :dodo_router, :cookie_suffix, ""

# Configures the endpoint
config :dodo_router, DodoRouterWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DodoRouterWeb.ErrorHTML, json: DodoRouterWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DodoRouter.PubSub,
  live_view: [signing_salt: "X83Pyxc/"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :dodo_router, DodoRouter.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  dodo_router: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  dodo_router: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger,
  level: :info,
  backends: [:console, {LoggerFileBackend, :info_log}, {LoggerFileBackend, :error_log}]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :logger, :info_log,
  path: "logs/info.log",
  level: :info,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  rotate: %{max_bytes: 10_485_760, keep: 5, compress: true}

config :logger, :error_log,
  path: "logs/error.log",
  level: :error,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  rotate: %{max_bytes: 10_485_760, keep: 5, compress: true}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
