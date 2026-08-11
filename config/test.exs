import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Set by scripts/dev-workspace.sh in each jj workspace's .envrc. Without it two
# workspaces running `mix test` at the same time share one test database and
# one test server port, and neither failure looks like what it is.
workspace_suffix =
  case System.get_env("DODO_WORKSPACE", "") do
    "" -> ""
    name -> "_" <> String.replace(name, "-", "_")
  end

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :dodo_router, DodoRouter.Repo,
  username: System.get_env("DB_USERNAME", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOSTNAME", "localhost"),
  database: "dodo_router_test#{workspace_suffix}#{System.get_env("MIX_TEST_PARTITION")}",
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :dodo_router, DodoRouterWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("TEST_PORT", "4002"))],
  secret_key_base: "wwgxtkRJg8HU8+ay2dMaj55xkV6/YKMIzozfVMxA+Z9pyiDtbcK+SCN7uh3OqwLq",
  server: true

# Enable SQL sandbox for concurrent transactional acceptance tests
config :dodo_router, :sql_sandbox, true

# In test we don't send emails
config :dodo_router, DodoRouter.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :dodo_router, :env, :test
