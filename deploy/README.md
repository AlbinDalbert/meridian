# Deploying to Kubernetes

Two [kustomize](https://kustomize.io) bases, with nothing deployment-specific in them:

- [`app/`](app): Meridian. Migrations run in an init container before each new version starts.
  Probes use `/healthz` and `/readyz`. The image defaults to `ghcr.io/albindalbert/meridian:main`.
  It is public and multi-arch (amd64 + arm64), so no pull secret is needed.
- [`postgres/`](postgres): a single Postgres with pgvector. Skip it if you already run Postgres.

Your hostnames, secrets, and image version live in an overlay in your own infrastructure repo,
not here.

## An overlay

```
meridian/
├── kustomization.yaml
├── ingress.yaml
├── config.env       # non-secret settings
├── secrets.env      # don't commit in plain text (see below)
└── postgres.env     # same
```

`kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: meridian

resources:
  # Pin `ref` to a tag or commit to control when manifest changes reach you.
  - https://github.com/AlbinDalbert/meridian//deploy/app?ref=main
  - https://github.com/AlbinDalbert/meridian//deploy/postgres?ref=main
  - ingress.yaml

images:
  - name: ghcr.io/albindalbert/meridian
    newTag: main # or a commit (sha-1a2b3c4) or a release (0.1.0)

configMapGenerator:
  - name: meridian-config
    envs: [config.env]

secretGenerator:
  - name: meridian-secrets
    envs: [secrets.env]
  - name: meridian-postgres
    envs: [postgres.env]
```

`config.env` (see `example.env` and `docs/design.md` for every variable):

```sh
# Must be the host clients and browsers use: the admin console's LiveView socket rejects
# other origins.
PHX_HOST=meridian.example.com
LLM_BASE_URL=http://my-inference-server:8080/v1
EXPOSE_UPSTREAM_MODELS=false
CORS_ALLOWED_ORIGINS=
# Optional sign-in (see the main README, "Signing in"). None of these are secrets.
OIDC_ISSUER=
OIDC_CLIENT_ID=
ADMIN_EMAILS=
OIDC_AUDIENCES=
```

`secrets.env` (no quotes around values; kustomize keeps them literally):

```sh
# The password must match postgres.env. Use one without URL special characters (hex is safe).
DATABASE_URL=ecto://meridian:PASSWORD@meridian-postgres/meridian
SECRET_KEY_BASE=   # openssl rand -base64 48
ADMIN_TOKEN=       # openssl rand -base64 48; leave empty to use only sign-in (or disable /admin)
OIDC_CLIENT_SECRET=   # only for a confidential client
LLM_API_KEY=
```

`postgres.env` (only read when the database is first created; changing it later doesn't change
the password):

```sh
POSTGRES_PASSWORD=   # openssl rand -hex 24
```

`ingress.yaml` (Traefik shown; TLS depends on your setup, e.g. cert-manager or Traefik's own
certificate resolver):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: meridian
spec:
  ingressClassName: traefik
  rules:
    - host: meridian.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: meridian
                port:
                  name: http
```

Meridian redirects plain HTTP to HTTPS unless the proxy sends `X-Forwarded-Proto: https`, which
Traefik does when it terminates TLS.

Deploy:

```sh
kubectl create namespace meridian
kubectl apply -k meridian/
```

If your infrastructure repo isn't private, keep the `.env` files out of it or encrypt them
(SOPS, Sealed Secrets). Changing a generated ConfigMap or Secret renames it, which rolls the
Deployment automatically.

## Updating

CI pushes a new image for every commit to `main` (`:main` and `:sha-<commit>`) and for every
version tag. Ways to roll it out, from least to most setup:

- **Follow `:main`**: `kubectl -n meridian rollout restart deploy/meridian`. The pod has
  `imagePullPolicy: Always`, so it pulls the latest `:main`.
- **Pin a version**: set `newTag` to `sha-<commit>` or a release and `kubectl apply -k` again.
  You always know what's running, and rolling back means changing the tag back.
- **Automate**: an image updater (Keel, Flux or Argo CD image automation) watches GHCR and
  rolls out new tags itself.

A rolling update starts the new pod (and its migrations) before stopping the old one. Runs in
progress on the old pod end as failed (`interrupted`) and clients can retry them. Everything
else is in Postgres.
