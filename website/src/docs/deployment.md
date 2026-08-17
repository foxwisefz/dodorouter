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
