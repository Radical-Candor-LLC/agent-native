#!/usr/bin/env bash
#
# Ongoing deploy for the self-hosted Plan service on GCP Cloud Run.
#
#   deploy/deploy.sh             build the current checkout, push, apply the
#                                manifest with the new image, and verify.
#   deploy/deploy.sh --rollback  shift traffic back to the previous revision.
#
# This mirrors the GitHub "Deploy Plan to Cloud Run" Action for local use. It
# builds via Cloud Build (no local Docker needed) and applies the multi-container
# manifest (deploy/plan-service.yaml) with the freshly built image digest, so the
# cloudflared sidecar is preserved (which `gcloud run deploy --source` cannot do).
set -euo pipefail

PROJECT="radical-candor-ai"
REGION="us-central1"
SERVICE="plan"
REPO="us-central1-docker.pkg.dev/${PROJECT}/cloud-run-source-deploy/plan"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT}/deploy/plan-service.yaml"

verify() {
  echo "==> Verifying"
  gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT" \
    --format='value(status.latestReadyRevisionName)'
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' https://an.radicalcandor.com/ || true)"
  echo "    https://an.radicalcandor.com/ -> HTTP ${code} (302 = live behind Cloudflare Access)"
}

if [ "${1:-}" = "--rollback" ]; then
  prev="$(gcloud run revisions list --service "$SERVICE" --region "$REGION" --project "$PROJECT" \
    --sort-by='~metadata.creationTimestamp' --format='value(metadata.name)' | sed -n '2p')"
  if [ -z "$prev" ]; then
    echo "No previous revision to roll back to." >&2
    exit 1
  fi
  echo "==> Rolling traffic back to ${prev}"
  gcloud run services update-traffic "$SERVICE" --region "$REGION" --project "$PROJECT" \
    --to-revisions "${prev}=100"
  verify
  exit 0
fi

TAG="$(git -C "$ROOT" rev-parse --short HEAD)"

echo "==> Building image ${REPO}:${TAG} (Cloud Build)"
gcloud builds submit --tag "${REPO}:${TAG}" --project "$PROJECT" "$ROOT"

echo "==> Resolving immutable digest"
DIGEST="$(gcloud artifacts docker images describe "${REPO}:${TAG}" --project "$PROJECT" \
  --format='value(image_summary.digest)')"
echo "    ${REPO}@${DIGEST}"

echo "==> Applying manifest (new revision, 100% traffic)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
sed -E "s#(image: )${REPO}@sha256:[0-9a-f]+#\1${REPO}@${DIGEST}#" "$MANIFEST" > "$TMP"
gcloud run services replace "$TMP" --region "$REGION" --project "$PROJECT"

verify
