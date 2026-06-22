# Self-hosting Plan on GCP Cloud Run (RC internal PoC)

This directory deploys the agent-native **Plan** template to **Google Cloud Run**
as a private service, fronted by a **Cloudflare Tunnel** and gated by **Cloudflare
Access** (Google Workspace SSO), backed by **Neon Postgres**. It serves at
`https://an.radicalcandor.com`.

```
Browser (RC Google Workspace user)
   │  https://an.radicalcandor.com
   ▼
Cloudflare Access ──── allow: email ∈ radicalcandor.com  (else → Google SSO)
   ▼  (Cloudflare Tunnel; cloudflared dials OUT — no inbound port)
Cloud Run service "plan"  (ingress public-blocked / private; 2 containers)
   ├─ app          Nitro node server (templates/plan/.output), port 8080
   └─ cloudflared  Cloudflare Tunnel sidecar (HTTP/2 transport)
   │
   ├──► Neon Postgres  (DATABASE_URL; runMigrations additive-only at boot)
   └──► Anthropic API  (in-app agent chat)
```

Why Cloud Run and not Cloudflare Workers/Pages: Plan's SSR worker (~13 MB) exceeds
the Workers startup-CPU limit, and the bloat is Vite-SSR-inlined client code that
`--external` cannot strip. Full-Node (Cloud Run) runs Plan unmodified. See
`docs/superpowers/specs/2026-06-22-self-host-plan-gcp-cloudrun-design.md` (local)
for the full rationale.

## Environment

| Thing | Value |
|---|---|
| GCP project | `radical-candor-ai` |
| Region | `us-central1` |
| Service | `plan` |
| Runtime SA | `225445667029-compute@developer.gserviceaccount.com` |
| Image repo | `us-central1-docker.pkg.dev/radical-candor-ai/cloud-run-source-deploy/plan` |
| Hostname | `an.radicalcandor.com` |
| Neon project | `red-feather-11884863` (pooled URL → `plan-database-url` secret) |
| Cloudflare Tunnel | `agent-native-plans` (token → `plan-tunnel-token` secret) |

## Files

- `plan-service.yaml` — the multi-container service spec (source of truth).
- `../Dockerfile` — builds the Plan node-server image (pnpm monorepo, root context).
- `../.dockerignore` — keeps the build context / image small and secret-free.

## Secrets (Secret Manager, one-time)

The app reads these via `secretKeyRef` in `plan-service.yaml`. Never commit values.

| Secret | Contents |
|---|---|
| `plan-database-url` | Neon **pooled** connection string |
| `plan-anthropic-key` | Anthropic API key |
| `plan-better-auth-secret` | stable 32-byte hex (`openssl rand -hex 32`) — must persist across deploys |
| `plan-oauth-state-secret` | 32-byte hex |
| `plan-tunnel-token` | Cloudflare Tunnel token for `agent-native-plans` |

Create + grant (repeat per secret):

```bash
printf '%s' "<value>" | gcloud secrets create plan-database-url --data-file=- --project radical-candor-ai
gcloud secrets add-iam-policy-binding plan-database-url \
  --member="serviceAccount:225445667029-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" --project radical-candor-ai
```

## Build & deploy

`gcloud run deploy --source` only supports one container, so we build the image
separately, then apply the multi-container spec with `services replace`.

```bash
# 1. Build + push the app image (uses the root Dockerfile, repo-root context).
cd "$(git rev-parse --show-toplevel)"
TAG="$(git rev-parse --short HEAD)"
gcloud builds submit \
  --tag "us-central1-docker.pkg.dev/radical-candor-ai/cloud-run-source-deploy/plan:${TAG}" \
  --project radical-candor-ai .

# 2. Point the spec at the new image (replace the `image:` digest/tag in
#    deploy/plan-service.yaml with the tag you just built, or its pinned digest).

# 3. Apply the service spec (creates a new revision, 100% traffic).
gcloud run services replace deploy/plan-service.yaml --region us-central1 --project radical-candor-ai
```

First boot runs `runMigrations` against Neon (additive-only; `drizzle-kit push` is
forbidden). Migrations are idempotent, so redeploys just do a cheap version check.

## Verify

```bash
# Revision became Ready (passed startup probe).
gcloud run services describe plan --region us-central1 --format='value(status.latestReadyRevisionName)'

# App SSRs a real 200 (bypass Access via an authenticated proxy).
gcloud run services proxy plan --region us-central1 --port 8089 &   # leave running
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8089/    # expect 200
kill %1

# Tunnel + Access intact: public URL bounces unauthenticated callers to Google SSO.
curl -sS -o /dev/null -w "%{http_code} -> %{redirect_url}\n" https://an.radicalcandor.com/  # expect 302 -> cloudflareaccess.com

# cloudflared registered its tunnel on the current revision.
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="plan" AND textPayload:"Registered tunnel connection"' \
  --limit 4 --freshness=15m --format='value(textPayload)' --project radical-candor-ai
```

## Rollback

Cloud Run keeps prior revisions. Shift traffic back instantly:

```bash
gcloud run revisions list --service plan --region us-central1
gcloud run services update-traffic plan --region us-central1 --to-revisions <good-revision>=100
```

## Cost / sizing

`cpu-throttling=false` + `minScale=1` keep one instance always running so the
tunnel connection stays alive — this is the always-on cost driver. Cloud Run
requires an integer ≥ 1 vCPU when CPU is always-allocated, so total instance CPU
is **1 vCPU**, split app `0.9` / cloudflared `0.1` (≈ half the original 2 vCPU).
At 0.9 vCPU the app memory caps at 1Gi (Cloud Run per-container CPU:memory rule).
`startup-cpu-boost` covers boot without adding steady-state cost.

To cut cost further you would move the tunnel off Cloud Run (e.g. a small always-on
VM running `cloudflared`, letting the app scale to zero with request-based billing)
— a re-architecture, not a config change.

## One-time infra (Cloudflare)

- **Tunnel** `agent-native-plans`: created in Zero Trust → Networks → Tunnels;
  public hostname `an.radicalcandor.com` → service `http://localhost:8080`. Token
  stored in `plan-tunnel-token`.
- **Access**: Zero Trust → Access → Applications → self-hosted app on
  `an.radicalcandor.com`; identity provider Google Workspace; policy **Allow**
  email domain `radicalcandor.com`, default **Deny**.

## Pending: "Sign in with Google" (Better Auth)

The app auto-enables Google social login when `GOOGLE_CLIENT_ID` +
`GOOGLE_CLIENT_SECRET` are present. Remaining (operator) step:

1. In the RC Google Cloud project, create an **OAuth 2.0 Client ID** (Web).
2. Authorized redirect URI (exact):
   `https://an.radicalcandor.com/_agent-native/auth/ba/google/callback`
3. Store the values as secrets `plan-google-client-id` / `plan-google-client-secret`
   (grant the runtime SA `secretAccessor`), add `GOOGLE_CLIENT_ID` /
   `GOOGLE_CLIENT_SECRET` env (from those secrets) to the `app` container in
   `plan-service.yaml`, and re-run `services replace`.

Note: Cloudflare Access already enforces Google Workspace SSO at the perimeter, so
this is a second, app-level Google login (one-click "Continue with Google" instead
of Better Auth email/password). Email/password works today without it.
