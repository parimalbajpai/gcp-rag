#!/usr/bin/env bash
#
# 06-deploy-ingestion.sh
# Build the ingestion image to Artifact Registry and deploy it to Cloud Run.
#
# WHAT THIS DOES
#   1. Ensures the Artifact Registry repo exists.
#   2. Submits a Cloud Build to build the container from services/ingestion/.
#   3. Deploys it to Cloud Run with:
#        - service account: ingestion-sa (least privilege)
#        - Cloud SQL connection (unix socket /cloudsql/<conn-name>)
#        - DB password injected from Secret Manager (--set-secrets)
#        - all other config via --set-env-vars
#        - ingress=all so Eventarc can deliver, but require auth (no public)
#   4. Prints the service URL.
#
# WHAT THIS DOES NOT DO
#   - Eventarc trigger (next script, 07-create-eventarc-trigger.sh).
#
# PREREQS
#   - 01..05 already run.
#   - APP DB password secret exists (created by 04).
#   - You're authenticated:  gcloud auth login
#
# RE-RUN SAFE
#   - AR repo create is gated on existence.
#   - `gcloud run deploy` updates in place.

set -euo pipefail

# ----- CONFIG -------------------------------------------------------------
. ./00-config.sh
# --------------------------------------------------------------------------

SERVICE="$INGESTION_SERVICE"
SOURCE_DIR="../services/ingestion"
IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${ARTIFACT_REGISTRY_REPO}/${SERVICE}"
IMAGE_TAG="$(date -u +%Y%m%d-%H%M%S)"
IMAGE_FULL="${IMAGE}:${IMAGE_TAG}"

echo "==> Project:  $GCP_PROJECT_ID"
echo "==> Region:   $GCP_REGION"
echo "==> Service:  $SERVICE"
echo "==> Image:    $IMAGE_FULL"
echo

gcloud config set project "$GCP_PROJECT_ID" >/dev/null

# ---------- ensure Artifact Registry repo --------------------------------
echo "==> Ensuring Artifact Registry repo '$ARTIFACT_REGISTRY_REPO'..."
if gcloud artifacts repositories describe "$ARTIFACT_REGISTRY_REPO" \
      --location="$GCP_REGION" >/dev/null 2>&1; then
  echo "    repo exists"
else
  gcloud artifacts repositories create "$ARTIFACT_REGISTRY_REPO" \
    --repository-format=docker \
    --location="$GCP_REGION" \
    --description="Container images for the PDF RAG project"
fi

# ---------- build the image ----------------------------------------------
echo "==> Submitting Cloud Build..."
if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "ERROR: source dir not found: $SOURCE_DIR (run from scripts/ folder)" >&2
  exit 1
fi

gcloud builds submit "$SOURCE_DIR" \
  --tag="$IMAGE_FULL" \
  --region="$GCP_REGION"

# Also tag :latest so manual rollouts pick up the freshest build.
gcloud artifacts docker tags add "$IMAGE_FULL" "${IMAGE}:latest" >/dev/null 2>&1 || true

# ---------- deploy to Cloud Run ------------------------------------------
echo "==> Deploying Cloud Run service '$SERVICE'..."

# Env vars consumed by app/settings.py + main.py
ENV_VARS=(
  "GCP_PROJECT_ID=${GCP_PROJECT_ID}"
  "GCP_REGION=${GCP_REGION}"
  "VERTEX_AI_REGION=${VERTEX_AI_REGION}"
  "DB_HOST=/cloudsql/${CLOUDSQL_CONNECTION_NAME}"
  "DB_PORT=5432"
  "DB_NAME=${DB_NAME}"
  "DB_USER=${DB_USER}"
  "EMBEDDING_MODEL=${EMBEDDING_MODEL}"
  "EMBEDDING_DIM=${EMBEDDING_DIM}"
  "EMBEDDING_BATCH_SIZE=100"
  "CHUNK_SIZE_CHARS=2000"
  "CHUNK_OVERLAP_CHARS=300"
  "PROCESSED_BUCKET=${GCS_BUCKET_PROCESSED}"
  "RAW_BUCKET=${GCS_BUCKET_RAW}"
  "LOG_LEVEL=INFO"
)
# Join with commas (Cloud Run accepts repeat --set-env-vars but a single one is cleaner)
ENV_JOINED="$(IFS=, ; echo "${ENV_VARS[*]}")"

gcloud run deploy "$SERVICE" \
  --image="$IMAGE_FULL" \
  --region="$GCP_REGION" \
  --platform=managed \
  --service-account="$SA_INGESTION_EMAIL" \
  --add-cloudsql-instances="$CLOUDSQL_CONNECTION_NAME" \
  --set-env-vars="$ENV_JOINED" \
  --set-secrets="DB_PASSWORD=${SECRET_DB_APP_PASSWORD}:latest" \
  --memory=1Gi \
  --cpu=1 \
  --concurrency=4 \
  --timeout=540 \
  --min-instances=0 \
  --max-instances=3 \
  --no-allow-unauthenticated \
  --ingress=all

URL="$(gcloud run services describe "$SERVICE" --region="$GCP_REGION" --format='value(status.url)')"
echo
echo "==> Deployed."
echo "    URL: $URL"
echo "    Image: $IMAGE_FULL"
echo
echo "Next: wire up the Eventarc trigger so GCS finalize events hit this service."
echo "      That'll be 07-create-eventarc-trigger.sh."
