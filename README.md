# Meridian

A self-hostable agent layer for any OpenAI-compatible inference endpoint.

Meridian sits between your clients and a model endpoint (llama.cpp, LiteLLM, vLLM, a hosted
provider, ...). It looks like an inference endpoint to clients, but your API key carries *you*:
your personas, your threads, and whatever extensions add on top.

- **Stateless `/v1/*`**: an OpenAI-compatible, persona-aware proxy. Point any OpenAI client at
  it and pick a persona as the model.
- **Stateful `/api/*` + WebSocket**: server-side threads and durable runs. A response keeps
  generating if the client disconnects, and clients can resume the event stream from where they
  left off.
- **Extensible**: the core is a run lifecycle with hooks; memory, tools, and skills are
  extensions.

> **Status:** early development. See [`docs/design.md`](docs/design.md) for the design and
> roadmap.

## Development

Requirements: Elixir 1.19 / Erlang OTP 28, and Docker (or another compose-compatible runtime)
for Postgres.

```sh
docker compose up -d   # Postgres (with pgvector) on localhost:5432
mix setup              # deps, database, migrations
mix phx.server         # http://localhost:4000
mix test
```

Before committing, run `mix precommit` (warnings as errors, unused deps, format, tests).

Health probes: `GET /healthz` (liveness) and `GET /readyz` (database reachable).

## Running

Images are published to `ghcr.io/albindalbert/meridian` for `linux/amd64` and `linux/arm64`.

```sh
docker run --rm \
  -e DATABASE_URL=ecto://USER:PASS@HOST/meridian \
  -e SECRET_KEY_BASE=... \
  ghcr.io/albindalbert/meridian:main /app/bin/migrate

docker run -p 4000:4000 \
  -e DATABASE_URL=ecto://USER:PASS@HOST/meridian \
  -e SECRET_KEY_BASE=... \
  -e PHX_HOST=meridian.example.com \
  ghcr.io/albindalbert/meridian:main
```

| Variable          | Required | Purpose |
|-------------------|----------|---------|
| `DATABASE_URL`    | yes      | Postgres connection, `ecto://USER:PASS@HOST/DB` |
| `SECRET_KEY_BASE` | yes      | 64+ byte secret (`mix phx.gen.secret`) |
| `PHX_HOST`        | no       | Public hostname (default `example.com`) |
| `PORT`            | no       | Listen port (default `4000`) |
| `POOL_SIZE`       | no       | Database pool size (default `10`) |
| `ECTO_IPV6`       | no       | `true` to connect to Postgres over IPv6 |

More configuration (inference upstream, extensions) will arrive with later milestones.
