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

### Signing in (OIDC, e.g. WorkOS AuthKit)

Instead of tokens and keys, operators and users can sign in through any OpenID Connect
provider: [WorkOS AuthKit](https://workos.com/docs/authkit), Keycloak, Authentik, Google, Entra.
Meridian signs people in with one client at the provider: set `OIDC_ISSUER`, `OIDC_CLIENT_ID`,
and `OIDC_CLIENT_SECRET` (for a confidential client; omit it for a public one, Meridian always
uses PKCE). Register the redirect URIs below with that client.

**Admin console.** Also set `ADMIN_EMAILS`. `/admin/login` then shows a "Sign in" button; you
get in if the provider says your email is verified and it's in `ADMIN_EMAILS`. Redirect URI:
`https://<PHX_HOST>/admin/auth/callback`. `ADMIN_TOKEN` can stay set as a fallback for when the
provider is down, or be left unset.

**Your own personas (`/me`).** On whenever the client is set. Any Meridian user can sign in at
`https://<PHX_HOST>/me` and create, edit, and delete their own personas (system prompt, model,
params, extensions) and pick their default. It has nothing to do with the admin console: its
own session, no `ADMIN_EMAILS`, and only your own things. Users are linked by email as below.
Redirect URI: `https://<PHX_HOST>/me/auth/callback`.

**Access requests.** With `/me` on, `https://<PHX_HOST>/me/request` is a public page where
anyone can leave their email (and a name) to ask to be added. Send it to friends; their
requests show up under Requests in the admin console, where Accept creates their user (with a
default persona on the model you pick there), Snooze puts it aside for later, and Reject turns
it down. Once accepted, they sign in with that email.

**Browser apps** (e.g. [xebec](../xebec)). On whenever the client is set. Meridian runs the
login for the app, like it does for `/admin`: the app links its "Sign in" button to
`/api/auth/login?return_to=/some/path`, Meridian sends the browser to the provider and back to
`/api/auth/callback`, and starts a session in a cookie that `/api` accepts instead of a bearer
token. The app must be served on the same origin as `/api` (a reverse proxy routing `/api` to
Meridian, as xebec's image does), and requests that change something must send an
`X-Requested-With` header. `GET /api/auth/session` says whether sign-in is available and who is
signed in, plus `account_url` (`/me` at Meridian's public URL, for apps to link to);
`POST /api/auth/logout` ends the session. Meridian's session only: the provider
keeps its own, so after logging out send `prompt=login` with the next `/api/auth/login` to have
the provider ask again (and let the person pick another account). Users are linked by email as below.
Redirect URI: `https://<app host>/api/auth/callback`; behind a proxy, Meridian builds it
from `X-Forwarded-Host` and `X-Forwarded-Proto`.

This is for apps without a backend of their own. They can't run the login themselves: the
provider's token endpoint would have to allow the app's origin for CORS, and WorkOS doesn't for
OAuth applications.

**Clients with their own login.** Set `OIDC_AUDIENCES` to the client ids of your apps. A client then runs the login
itself (with the provider's SDK, using PKCE) and sends the access token as
`Authorization: Bearer <token>` where it would send an API key. Meridian checks the signature
(RS256, keys from the provider's JWKS), issuer, audience, and expiry. The first time someone
signs in, they are linked to the Meridian user with the same email (fetched from the provider's
userinfo endpoint, so request the `openid email` scopes). There is no signup: create the user
in the admin console first. Signed-in users can use all of their personas. API keys keep
working, and are still the way in for generic OpenAI clients.

With WorkOS:

1. In the WorkOS dashboard, under AuthKit, note your AuthKit domain. That is `OIDC_ISSUER`,
   e.g. `https://your-name.authkit.app`.
2. Under Connect, create an OAuth application for Meridian: first-party, confidential, with the
   redirect URIs `https://<PHX_HOST>/admin/auth/callback`, `https://<PHX_HOST>/me/auth/callback`,
   and `https://<app host>/api/auth/callback` for each browser app. Its client id and secret are
   `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET`.
3. For clients that run the login themselves, create a first-party application each (public,
   with the client's own redirect URI) and add its client id to `OIDC_AUDIENCES`.

Other endpoints: `GET /api/personas` (the personas the caller may use, as `{id, name, model,
default}`; `id` is what threads take as `persona`), `GET/PATCH/DELETE /api/threads/:id`, `GET /api/runs/:id`, and
`POST /api/runs/:id/cancel`. The admin console shows how Meridian is used (per user:
threads, messages, runs, tokens; per run: status, timings, usage, and a live log of its events
by type), never what anyone said.

Before committing, run `mix precommit` (warnings as errors, unused deps, format, tests, Dialyzer).

Health probes: `GET /healthz` (liveness) and `GET /readyz` (database reachable). To deploy on
Kubernetes, see [`deploy/README.md`](deploy/README.md).

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
| `ADMIN_TOKEN`     | no       | Enables `/admin` and is the secret to log in with (32+ chars). With neither this nor `ADMIN_EMAILS` set, the admin console is disabled |
| `OIDC_ISSUER`     | no       | OIDC provider for sign-in, exactly as its tokens' `iss` (e.g. `https://your-name.authkit.app`). See [Signing in](#signing-in-oidc-eg-workos-authkit) |
| `OIDC_CLIENT_ID`  | no       | Meridian's client at the provider. Enables user sign-in for browser apps (`/api/auth`), and admin sign-in with `ADMIN_EMAILS` |
| `OIDC_CLIENT_SECRET` | no    | That client's secret (confidential clients; omit for a public client) |
| `ADMIN_EMAILS`    | no       | Comma-separated emails allowed into `/admin` via sign-in. Needs `OIDC_CLIENT_ID` |
| `OIDC_AUDIENCES`  | no       | Comma-separated client ids whose access tokens `/v1` and `/api` accept. Unset means API keys only |

\* Meridian starts without it, but can't serve completions.
