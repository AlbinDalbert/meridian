# Meridian

A self-hostable agent layer for any OpenAI-compatible inference endpoint.

Meridian sits between your clients and that endpoint. To a client it looks
like an inference endpoint, but your API key carries you: your agents, your threads, and
whatever your extensions add.

- **`/v1`** is an OpenAI-compatible proxy. Point any OpenAI client at it and pick an agent as
  the model.
- **`/api`** keeps threads on the server. A reply keeps generating if the client disconnects,
  and the client can resume the event stream where it left off.
- **Extensions** are sandboxed Lua scripts, edited in the browser. They hook into every run
  and can add tools. [The guide](docs/guide/01-extensions/01-introduction.md) explains how to write them; a running
  Meridian serves it at `/docs`.
- **Skills** are instructions the model loads when a task calls for them.

Status: early development. [`docs/design.md`](docs/design.md) explains how it works and why.

## Development

You need Elixir 1.19 with OTP 28, and Docker or another compose runtime for Postgres.

```sh
docker compose up -d   # Postgres on localhost:5432
cp example.env .env    # edit as needed; read automatically in development
mix setup              # deps, database, migrations
mix phx.server         # http://localhost:4000
```

`example.env` lists every variable, with values for a local [Ollama](https://ollama.com).
Any other OpenAI-compatible upstream works the same way. Meridian uses its `/chat/completions`
with streaming, and its `/models` to check an agent's model when you save the agent.

Open `http://localhost:4000/admin` and log in with `ADMIN_TOKEN`. Create a user, which also
creates their `meridian/default` agent, and mint an API key for them. Then point any OpenAI
client at `http://localhost:4000/v1` with that key.

Run `mix precommit` before committing. It compiles with warnings as errors, formats, and runs
the tests and Dialyzer.

## Using the native API

```sh
KEY=mrd_...
THREAD=$(curl -s -H "authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d '{"title": "Hello"}' localhost:4000/api/threads | jq -r .data.id)
RUN=$(curl -s -H "authorization: Bearer $KEY" -H 'content-type: application/json' \
  -d '{"content": "Hi!"}' localhost:4000/api/threads/$THREAD/messages | jq -r .data.run.id)
curl -N -H "authorization: Bearer $KEY" localhost:4000/api/runs/$RUN/events   # SSE
# Resume after the last event you saw with `Last-Event-ID: <id>` or `?after=<id>`.
```

The design doc has [the full route list](docs/design.md#api-native-stateful).

Browser apps need their origin in `CORS_ALLOWED_ORIGINS`. `EventSource` can't send an
`Authorization` header, so every run in an API response carries an `events_token` for its
stream:

```js
const es = new EventSource(`${base}/api/runs/${run.id}/events?token=${encodeURIComponent(run.events_token)}`);
es.addEventListener("message.delta", (e) => render(JSON.parse(e.data).payload));
es.addEventListener("run.completed", () => es.close());
```

The token reads only that run's events and expires after an hour. Once a run has ended, a
reconnect gets `204`, which makes `EventSource` stop.

## Signing in with OIDC

Meridian can sign people in through any OpenID Connect provider, such as WorkOS AuthKit,
Keycloak, Authentik, Google, or Entra. It uses one client at the provider, always with PKCE.
Set `OIDC_ISSUER` and `OIDC_CLIENT_ID`, plus `OIDC_CLIENT_SECRET` for a confidential client.
That turns on:

- **`/me`**, where users manage their own agents, extensions, and skills. Redirect URI
  `https://<PHX_HOST>/me/auth/callback`.
- **`/me/request`**, a public page where people ask for access. Requests show up in the admin
  console, where accepting one creates the user.
- **Admin sign-in**, if you also set `ADMIN_EMAILS`. Redirect URI
  `https://<PHX_HOST>/admin/auth/callback`. `ADMIN_TOKEN` can stay as a fallback.
- **Sign-in for browser apps** without a backend. The app links to
  `/api/auth/login?return_to=/path`, and Meridian runs the login and sets a cookie that `/api`
  accepts. The app must be served on the same origin as `/api`, and requests that change
  something must send `X-Requested-With`. Redirect URI `https://<app host>/api/auth/callback`.
  `GET /api/auth/session` tells the app who is signed in.

Clients that run their own login can send the provider's access token instead of an API key.
List their client ids in `OIDC_AUDIENCES`.

There is no signup. A person's first sign-in links them to the existing user with the same
email, so create the user first, or accept their access request.

With WorkOS:

1. Your AuthKit domain is `OIDC_ISSUER`, e.g. `https://your-name.authkit.app`.
2. Under Connect, create a first-party, confidential OAuth application for Meridian with the
   redirect URIs above. Its client id and secret are `OIDC_CLIENT_ID` and
   `OIDC_CLIENT_SECRET`.
3. For each client that runs its own login, create a public first-party application and add its
   client id to `OIDC_AUDIENCES`.

## Running

Images for `linux/amd64` and `linux/arm64` are on `ghcr.io/albindalbert/meridian`.

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

`GET /healthz` is the liveness probe and `GET /readyz` checks the database. For Kubernetes, see
[`deploy/README.md`](deploy/README.md).

| Variable | Required | Purpose |
|---|---|---|
| `DATABASE_URL` | yes | Postgres, `ecto://USER:PASS@HOST/DB` |
| `SECRET_KEY_BASE` | yes | 64+ byte secret from `mix phx.gen.secret` |
| `PHX_HOST` | no | Public hostname. Default `example.com` |
| `PORT` | no | Listen port. Default `4000` |
| `POOL_SIZE` | no | Database pool size. Default `10` |
| `ECTO_IPV6` | no | `true` to reach Postgres over IPv6 |
| `LLM_BASE_URL` | yes\* | The upstream, including `/v1` |
| `LLM_API_KEY` | no | Upstream API key, sent as a bearer token |
| `EXPOSE_UPSTREAM_MODELS` | no | `true` to also list raw upstream models on `/v1/models` |
| `CORS_ALLOWED_ORIGINS` | no | Comma-separated browser origins allowed to call `/v1` and `/api`, or `*` |
| `ADMIN_TOKEN` | no | Secret for logging into `/admin`, 32+ characters |
| `ADMIN_EMAILS` | no | Comma-separated emails allowed into `/admin` through OIDC sign-in |
| `OIDC_ISSUER` | no | The provider, exactly as its tokens' `iss` |
| `OIDC_CLIENT_ID` | no | Meridian's client at the provider. Turns on `/me`, `/api/auth`, and admin sign-in |
| `OIDC_CLIENT_SECRET` | no | That client's secret. Leave it out for a public client |
| `OIDC_AUDIENCES` | no | Comma-separated client ids whose access tokens `/v1` and `/api` accept |
| `DNS_CLUSTER_QUERY` | no | DNS name for finding other nodes when clustering |

\* Meridian starts without it but can't generate replies.

With neither `ADMIN_TOKEN` nor `ADMIN_EMAILS`, `/admin` is off.
