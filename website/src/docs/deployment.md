---
title: Deployment
description: Elixir release boot sequence, migrations, and health checks for production.
section: Operations
order: 18
---

# Deployment

DodoRouter ships as an Elixir release (`mix release`) with full ERTS included, so a deployed instance doesn't need Elixir/Erlang installed on the target machine — just PostgreSQL reachable and the environment variables from [Self-hosting](/docs/self-hosting/#production-environment-variables) set.

A minimal production boot looks like:

```bash
MIX_ENV=prod mix release
DATABASE_URL=ecto://user:pass@host/dodo_router_prod \
SECRET_KEY_BASE=$(mix phx.gen.secret) \
PHX_HOST=your-domain.com \
PHX_SERVER=true \
INFISICAL_TOKEN=… INFISICAL_PROJECT_ID=… \
_build/prod/rel/dodo_router/bin/dodo_router start
```

Run database migrations before starting a new version: `bin/dodo_router eval DodoRouter.Release.migrate`. Health-check your deployment against `GET /health`, which returns 503 both when the database is unreachable and while the instance is intentionally draining connections during a graceful shutdown — point your load balancer's health check at it so it stops sending traffic during a rolling deploy.

## GitHub Actions and Tailscale

The app and website deployment workflows use `tailscale/github-action@v4` with
the existing `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, and `tag:github`. The OAuth
client needs permission to create auth keys for that tag, as described in the
[action's setup instructions](https://github.com/tailscale/github-action).

The older v2 action installs Tailscale 1.42.0, whose OAuth support requires an
experimental environment flag. On runners where `sudo -E` does not preserve
the environment, it exits with `oauth authkeys are in experimental status`
before authenticating. Use v4's newer client; rotating credentials does not
repair a missing environment flag.

After merging a workflow correction, start a fresh run from the updated branch.
GitHub's **Re-run jobs** uses the original commit and therefore the old workflow.
Website documentation changes on `main` automatically start **Deploy Website**;
workflow-only changes require its **Run workflow** action.

The **Build & Release** workflow publishes with `GITHUB_TOKEN`, whose release
event does not trigger another workflow. Start **Deploy to Production** with
**Run workflow**, select `main`, and enter the published version without its
`v` prefix. Leave **Force full install** disabled for a normal hot upgrade;
enable it only when required by an OTP/ERTS change. Confirm the running version
at `GET /api/version` and health at `GET /health` after deployment.

## Upgrading to multiple router API keys

For migration `20260925222451_create_router_api_keys`, stop all application instances, run migrations, then start the new release. This transition needs a restart rather than a hot or rolling upgrade: the old release can create or regenerate a key after the migration has copied the existing credentials, leaving the new key out of the new table.

Existing credentials are preserved as keys named **Default**. Once the new release is running, additional keys can be created and revoked independently. Do not roll back to a single-key release after managing keys: it cannot authenticate additional keys and its legacy router columns do not reflect revocations.
