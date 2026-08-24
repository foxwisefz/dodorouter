---
title: Self-hosting
description: Prerequisites, environment variables, and first boot for running your own DodoRouter instance.
section: Get Started
order: 3
---

# Self-hosting

DodoRouter is a standard Phoenix 1.8 application backed by PostgreSQL. Source: [github.com/foxwise-ai/dodorouter](https://github.com/foxwise-ai/dodorouter). License terms are covered in [License](#license) below — in short, free to self-host and modify, but you can't resell it as your own competing hosted service.

## Prerequisites

- Elixir 1.15+ and a matching Erlang/OTP
- PostgreSQL 12+
- An [Infisical](https://infisical.com) project (free tier is fine) — see the callout below, this is currently required, not optional

<div class="docs-callout docs-callout-warn my-2">
  <p class="docs-callout-title">⚠ Infisical is currently required</p>
  <p>Every provider API key you add (OpenAI, Anthropic, z.ai, …) is stored via <a href="https://infisical.com" target="_blank" rel="noopener noreferrer">Infisical</a>, a secrets manager — there is currently no local/plaintext fallback in the code. Without <code>INFISICAL_TOKEN</code> and <code>INFISICAL_PROJECT_ID</code> set, the app boots fine and the dashboard loads, but clicking <strong>Add Key</strong> on the Providers page will fail with "Failed to store API key securely" — so you won't be able to configure any provider, and no requests will succeed. Sign up at Infisical, create a project, create a Machine Identity with a Universal Auth client, and use that identity's access token as <code>INFISICAL_TOKEN</code>.</p>
</div>

## 1. Clone and install

```bash
git clone https://github.com/foxwise-ai/dodorouter.git
cd dodorouter
mix deps.get
```

## 2. Configure environment variables

For local development, export these before starting the server (e.g. in `.envrc` with [direnv](https://direnv.net), or a `.env` you source):

```bash
# Database — defaults match config/dev.exs; override if yours differs
export DB_USERNAME=postgres
export DB_PASSWORD=postgres
export DB_HOSTNAME=localhost
export DB_PORT=5432
export DB_NAME=dodo_router_dev

# Infisical — required, see callout above
export INFISICAL_TOKEN="<your machine identity access token>"
export INFISICAL_PROJECT_ID="<your infisical project id>"
export INFISICAL_ENVIRONMENT=dev   # optional, defaults to "prod"
```

## 3. Set up the database

```bash
mix ecto.setup
```

## 4. Start the server

```bash
mix phx.server
```

Visit `http://localhost:4000`. Register an account, confirm via the magic-link email — in dev, DodoRouter uses Swoosh's local mailbox instead of sending real email, so open `http://localhost:4000/dev/mailbox` to read it. From there, follow the same steps as the [Quickstart](/docs/quickstart/).

Verified: `GET /health` returns `{"status":"ok"}` once the DB connection is healthy, and `GET /api/version` returns the running app version, e.g. `{"version":"0.1.75"}` — handy for confirming the app booted and for health-check probes.

## Production environment variables

| Variable | Required | Notes |
|---|---|---|
| `DATABASE_URL` | Yes | e.g. `ecto://user:pass@host/dodo_router_prod` |
| `SECRET_KEY_BASE` | Yes | Generate with `mix phx.gen.secret` |
| `PHX_HOST` | Yes | Your public domain |
| `PHX_SERVER` | Yes | Set to `true` to actually start the endpoint under a release |
| `PORT` | No | Defaults to 4000 |
| `INFISICAL_TOKEN` | Yes* | *Required for provider-key storage to work at all (see callout above) |
| `INFISICAL_PROJECT_ID` | Yes* | Paired with the token above |
| `INFISICAL_ENVIRONMENT` | No | Defaults to `prod` |
| `RESEND_API_KEY` | No | Transactional email (magic links). Without it in prod, mail simply won't send |
| `EMAIL_FROM` | No | Defaults to `noreply@dodorouter.com` |
| `STRIPE_SECRET_KEY` | No | Only set this if you want the $19/mo billing paywall enabled. Unset = billing disabled, everyone has full access |
| `STRIPE_WEBHOOK_SECRET` | No | Required only alongside `STRIPE_SECRET_KEY` |
| `ECTO_IPV6` | No | Set to `true` to enable IPv6 for the DB socket |
| `POOL_SIZE` | No | Ecto pool size, defaults to 10 |
| `ATTESTO_ISSUER` | No | OAuth issuer URL for the [agent surface](/docs/agent-access/#self-hosting). Defaults to `https://` + `PHX_HOST`. Read at boot, so changing it just needs a restart |
| `ATTESTO_AUDIENCE` | No | OAuth resource identifier. Defaults to `<issuer>/mcp` |
| `ATTESTO_TRUSTED_PROXIES` | No | Comma-separated IPs/CIDRs of TLS-terminating proxies whose `X-Forwarded-Proto` the OAuth endpoints believe. Defaults to loopback, which covers a reverse proxy on the same machine; set it when the proxy reaches the app [across a network](/docs/agent-access/#self-hosting) |
| `ATTESTO_SIGNING_KEY_PATH` | For the agent surface | Absolute path to the EC P-256 PEM that signs OAuth access tokens: `openssl ecparam -name prime256v1 -genkey -noout -out oauth_signing_key.pem && chmod 600 oauth_signing_key.pem`. Without it, the whole OAuth flow works up to the final token exchange, which then fails — consent screens render, tokens never mint. (`ATTESTO_SIGNING_KEY_PEM` also works for environments that can pass a multi-line value inline; systemd's `EnvironmentFile` cannot) |

For deploy specifics (hot code upgrades, systemd, Castle release management), see the project's own `AGENTS.md` in the repo — those are maintainer-facing operational details rather than user-facing setup, so we won't duplicate them here. See also [Deployment](/docs/deployment/) for a minimal production boot sequence.

## License

DodoRouter is source-available under the [O'Saasy License](https://osaasy.dev). In short: you're free to use, modify, self-host, and even sell copies of it — the one thing you can't do is turn around and offer it as a competing hosted/managed service where the software itself is the product. See the full license text in the repository for the exact terms.
