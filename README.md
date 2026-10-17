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

To use it locally, point it at an upstream and set an admin token. `example.env` lists every
variable, with values for a local [Ollama](https://ollama.com):

```sh
cp example.env .env   # gitignored; edit as needed. Read automatically in development
mix phx.server
```

Then open `http://localhost:4000/admin`, log in with the token, create a user (this also creates
their `meridian/default` persona), and mint an API key. Point any OpenAI client at
`http://localhost:4000/v1` with that key and pick a persona as the model.

The native API keeps the conversation on the server. A reply keeps generating if the client
goes away; reconnect to the event stream to pick up where you left off:

```sh
KEY=mrd_...   # an API key minted in the admin console
THREAD=$(curl -s -H "authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d '{"title": "Hello"}' localhost:4000/api/threads | jq -r .data.id)
RUN=$(curl -s -H "authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d '{"content": "Hi!"}' localhost:4000/api/threads/$THREAD/messages | jq -r .data.run.id)
curl -N -H "authorization: Bearer $KEY" localhost:4000/api/runs/$RUN/events   # SSE
# Resume after the last event you saw with `Last-Event-ID: <id>` or `?after=<id>`.
curl -s -H "authorization: Bearer $KEY" localhost:4000/api/threads/$THREAD/messages
```

**Browser apps** are supported clients. Set `CORS_ALLOWED_ORIGINS` to the app's origin. The
app sends the key as `Authorization: Bearer` on every request. For the event stream, either read
it with `fetch` (which can send the header), or use `EventSource` with the run's
`events_token` (included in every run in API responses), since `EventSource` can't send
headers:

```js
const es = new EventSource(`${base}/api/runs/${run.id}/events?token=${encodeURIComponent(run.events_token)}`);
es.addEventListener("message.delta", (e) => render(JSON.parse(e.data).payload));
es.addEventListener("run.completed", () => es.close());
```

The token only reads that run's events, expires after an hour, and stops working when the key
is revoked. `EventSource` resumes on its own after a dropped connection (it sends
`Last-Event-ID`); once a run has ended, a reconnect gets `204`, which makes it stop.

Other endpoints: `GET/PATCH/DELETE /api/threads/:id`, `GET /api/runs/:id`, and
`POST /api/runs/:id/cancel`. The admin console shows threads and runs, including a live view
of a run as it generates.

Before committing, run `mix precommit` (warnings as errors, unused deps, format, tests, Dialyzer).

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
| `LLM_BASE_URL`    | yes\*    | OpenAI-compatible upstream, including `/v1` (e.g. `https://example.com/v1`) |
| `LLM_API_KEY`     | no       | Upstream API key, sent as a bearer token |
| `EXPOSE_UPSTREAM_MODELS` | no | `true` to also list raw upstream models in `/v1/models` |
| `CORS_ALLOWED_ORIGINS` | no  | Browser apps allowed to call `/v1` and `/api`: comma-separated origins (`https://chat.example.com,http://localhost:5173`) or `*`. Unset means none |
| `ADMIN_TOKEN`     | no       | Enables `/admin` and is the secret to log in with (32+ chars). Unset disables the admin console |

\* Meridian starts without it, but can't serve completions.
