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
#     PHX_SERVER=true bin/dodo_router start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :dodo_router, DodoRouterWeb.Endpoint, server: true
end

# Stripe billing — applies to all environments. Billing is disabled when
# STRIPE_SECRET_KEY is unset (the default in dev/test): paywall checks
# pass through and no Stripe calls are made.
if stripe_secret_key = System.get_env("STRIPE_SECRET_KEY") do
  config :stripity_stripe, api_key: stripe_secret_key

  config :dodo_router, :billing,
    enabled: true,
    webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET"),
    price_lookup_key: System.get_env("BILLING_PRICE_LOOKUP_KEY", "dodo_router_monthly_19"),
    trial_days: String.to_integer(System.get_env("BILLING_TRIAL_DAYS", "0"))
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :dodo_router, DodoRouter.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
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
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :dodo_router, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :dodo_router, DodoRouterWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :dodo_router, DodoRouterWeb.Endpoint,
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
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :dodo_router, DodoRouterWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # Resend for transactional emails
  config :dodo_router, DodoRouter.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: System.get_env("RESEND_API_KEY")

  config :dodo_router, :email_from, System.get_env("EMAIL_FROM", "noreply@dodorouter.com")
  config :dodo_router, :email_reply_to, System.get_env("EMAIL_REPLY_TO")

  # ATTESTO_ISSUER/ATTESTO_AUDIENCE must be read at boot, not baked into the
  # release at compile time (dodo_router-16u) — a value set in the server's
  # .env has no effect otherwise. Default the issuer to this endpoint's public
  # URL (same host runtime.exs already resolved above) and the audience to
  # issuer <> "/mcp", so OAuth discovery documents advertise the real host
  # rather than https://localhost.
  attesto_issuer = System.get_env("ATTESTO_ISSUER") || "https://#{host}"
  attesto_audience = System.get_env("ATTESTO_AUDIENCE") || "#{attesto_issuer}/mcp"

  # Which peers' X-Forwarded-* headers attesto believes. TLS terminates at the
  # edge proxy, so this is how a request over plain loopback HTTP proves it
  # arrived over HTTPS; with an empty list every OAuth endpoint refuses with
  # "the request must be made over TLS". Defaults to loopback (Caddy on the
  # same box); a proxy reaching the app across a network sets its CIDRs here,
  # comma-separated: ATTESTO_TRUSTED_PROXIES=172.16.0.0/12,10.0.0.5
  attesto_trusted_proxies =
    case System.get_env("ATTESTO_TRUSTED_PROXIES") do
      nil -> [:loopback]
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :dodo_router, AttestoPhoenix.Config,
    issuer: attesto_issuer,
    audience: attesto_audience,
    trusted_proxies: attesto_trusted_proxies
end
