#!/usr/bin/env bash
#
# 08-deploy-query.sh
# Build the query image to Artifact Registry and deploy it to Cloud Run.
#
# WHAT THIS DOES
#   1. Re-uses the Artifact Registry repo created by 06-deploy-ingestion.sh
#      (creates it if missing, just to be re-runnable independently).
#   2. Submits a Cloud Build to build the container from services/query/.
#   3. Deploys it to Cloud Run with:
#        - service account: query-sa (least privilege; no GCS access)
#        - Cloud SQL connection (unix socket /cloudsql/<conn-name>)
#        - DB password injected from Secret Manager (--set-secrets)
#        - --no-allow-unauthenticated (callers need an OIDC ID token)
#   4. Prints the service URL + a curl recipe.
#
# RE-RUN SAFE: AR repo create is gated; `gcloud run deploy` updates in place.

set -euo pipefail

# ----- CONFIG -------------------------------------------------------------
. ./00-config.sh
# --------------------------------------------------------------------------

SERVICE="$QUERY_SERVICE"
SOURCE_DIR="../services/query"
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

gcloud artifacts docker tags add "$IMAGE_FULL" "${IMAGE}:latest" >/dev/null 2>&1 || true

# ---------- deploy to Cloud Run ------------------------------------------
echo "==> Deploying Cloud Run service '$SERVICE'..."

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
  "LLM_MODEL=gemini-2.0-flash-001"
  "RETRIEVE_TOP_K=20"
  "FINAL_TOP_K=8"
  "RRF_K=60"
  "HNSW_EF_SEARCH=80"
  "LOG_LEVEL=INFO"
)
ENV_JOINED="$(IFS=, ; echo "${ENV_VARS[*]}")"

gcloud run deploy "$SERVICE" \
  --image="$IMAGE_FULL" \
  --region="$GCP_REGION" \
  --platform=managed \
  --service-account="$SA_QUERY_EMAIL" \
  --add-cloudsql-instances="$CLOUDSQL_CONNECTION_NAME" \
  --set-env-vars="$ENV_JOINED" \
  --set-secrets="DB_PASSWORD=${SECRET_DB_APP_PASSWORD}:latest" \
  --memory=1Gi \
  --cpu=1 \
  --concurrency=8 \
  --timeout=120 \
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
echo "Smoke test (authenticated curl):"
cat <<EOF
  TOKEN=\$(gcloud auth print-identity-token)
  curl -sS -X POST "$URL/query" \\
    -H "Authorization: Bearer \$TOKEN" \\
    -H "Content-Type: application/json" \\
    -d '{"question":"Summarize this resume in two sentences."}' \\
    | python3 -m json.tool
EOF
