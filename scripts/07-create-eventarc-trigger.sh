#!/usr/bin/env bash
#
# 07-create-eventarc-trigger.sh
# Create an Eventarc trigger that invokes the ingestion Cloud Run service
# whenever a new object is finalized in the raw bucket.
#
# WHAT WE'RE BUILDING
#
#   GCS raw bucket  --(object.finalized)-->  Eventarc  --(HTTP POST)-->  Cloud Run (ingestion)
#
# Eventarc takes a CloudEvent and turns it into an authenticated HTTPS POST.
# It uses a service account ("trigger SA") to mint the OIDC token that
# proves to Cloud Run that this invocation is allowed. We reuse the
# ingestion-sa for this — it already has roles/run.invoker and
# roles/eventarc.eventReceiver from script 03.
#
# REQUIRED IAM PLUMBING (this is the part that catches everyone the first time)
#
#   For *Cloud Storage* event sources specifically, Eventarc publishes the
#   CloudEvent to an internal Pub/Sub topic — and Pub/Sub messages from GCS
#   are produced by the Cloud Storage service agent. So that agent needs
#   roles/pubsub.publisher on the project. We grant it here.
#
#   The Eventarc service agent itself (service-<num>@gcp-sa-eventarc...) gets
#   roles/eventarc.serviceAgent automatically when the API is enabled. We
#   don't touch it.
#
# FILTERS
#   type=google.cloud.storage.object.v1.finalized
#   bucket=$GCS_BUCKET_RAW
#
# Note: Eventarc's bucket filter is a single-bucket exact match. We further
# defend in code by checking RAW_BUCKET in the FastAPI handler (main.py).
#
# TRIGGER LOCATION
#   Eventarc's GCS source requires the trigger location to match the bucket's
#   location. Our raw bucket is in $GCP_REGION (e.g., asia-south1). Cloud Run
#   service is also in $GCP_REGION, so they line up.
#
# IDEMPOTENT
#   - IAM grants use add-iam-policy-binding (no-op if already present).
#   - Trigger create is guarded on existence; if it exists, we update its
#     destination/SA in case anything drifted.
#
# PREREQS
#   - 06-deploy-ingestion.sh has been run (Cloud Run service exists).

set -euo pipefail

# ----- CONFIG -------------------------------------------------------------
. ./00-config.sh
# --------------------------------------------------------------------------

TRIGGER_NAME="${INGESTION_SERVICE}-on-gcs-finalized"
EVENT_TYPE="google.cloud.storage.object.v1.finalized"

echo "==> Project:  $GCP_PROJECT_ID"
echo "==> Region:   $GCP_REGION"
echo "==> Bucket:   gs://$GCS_BUCKET_RAW"
echo "==> Service:  $INGESTION_SERVICE"
echo "==> Trigger:  $TRIGGER_NAME"
echo

gcloud config set project "$GCP_PROJECT_ID" >/dev/null

# ---------- look up project number for service-agent emails --------------
echo "==> Resolving project number..."
PROJECT_NUMBER="$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)')"
if [[ -z "$PROJECT_NUMBER" ]]; then
  echo "ERROR: could not resolve project number for $GCP_PROJECT_ID" >&2
  exit 1
fi
echo "    project number: $PROJECT_NUMBER"

# Cloud Storage service agent (publishes Pub/Sub messages on GCS finalize events).
# IMPORTANT: this agent isn't auto-created in a project until something asks
# for it. `gcloud storage service-agent` provisions it (idempotent) and
# returns its email. We *don't* hard-code the email pattern because Google
# has changed it over time (gs-project-accounts vs gcp-sa-storage).
echo "==> Provisioning the Cloud Storage service agent (idempotent)..."
GCS_SA="$(gcloud storage service-agent --project="$GCP_PROJECT_ID")"
if [[ -z "$GCS_SA" ]]; then
  echo "ERROR: failed to obtain the GCS service agent email." >&2
  exit 1
fi
# Strip any whitespace/newlines just in case.
GCS_SA="$(echo "$GCS_SA" | tr -d '[:space:]')"
echo "    GCS service agent: $GCS_SA"

# ---------- ensure Cloud Run service exists ------------------------------
echo "==> Checking that Cloud Run service '$INGESTION_SERVICE' exists in $GCP_REGION..."
if ! gcloud run services describe "$INGESTION_SERVICE" --region="$GCP_REGION" >/dev/null 2>&1; then
  echo "ERROR: Cloud Run service '$INGESTION_SERVICE' not found in $GCP_REGION." >&2
  echo "       Run 06-deploy-ingestion.sh first." >&2
  exit 1
fi
echo "    OK"

# ---------- grant the GCS service agent pubsub.publisher -----------------
# This is the single most common reason Eventarc GCS triggers silently fail.
echo "==> Granting roles/pubsub.publisher to GCS service agent ($GCS_SA)..."
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:${GCS_SA}" \
  --role="roles/pubsub.publisher" \
  --condition=None \
  >/dev/null
echo "    OK"

# ---------- ensure the Eventarc service agent exists & has its role ------
# Eventarc validates the trigger source (bucket exists, etc.) by calling
# storage.buckets.get *as itself* — the Eventarc service agent. That agent:
#   - is created lazily; force-provision it with `services identity create`.
#   - gets roles/eventarc.serviceAgent auto-granted, but the binding can
#     take ~60s to propagate. We re-assert it explicitly for safety.
EVENTARC_SA="service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com"
echo "==> Provisioning the Eventarc service agent ($EVENTARC_SA)..."
# Use the GA command. (Earlier versions of this script used `gcloud beta`,
# but if the beta component isn't installed gcloud prompts interactively
# and reads from /dev/tty, so the call hangs forever even with stdout
# redirected.) --quiet suppresses any remaining prompts.
gcloud services identity create \
  --service=eventarc.googleapis.com \
  --project="$GCP_PROJECT_ID" \
  --quiet \
  >/dev/null 2>&1 || true

echo "==> Re-asserting roles/eventarc.serviceAgent on $EVENTARC_SA..."
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:${EVENTARC_SA}" \
  --role="roles/eventarc.serviceAgent" \
  --condition=None \
  >/dev/null
echo "    OK"

# ---------- (defensive) ensure ingestion-sa has the receiver/invoker roles
# Script 03 already grants these, but if someone re-ordered the steps or
# tightened roles later, we re-assert here so the trigger doesn't 403.
echo "==> Re-asserting ingestion-sa has eventarc.eventReceiver + run.invoker..."
for role in roles/eventarc.eventReceiver roles/run.invoker; do
  gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:${SA_INGESTION_EMAIL}" \
    --role="$role" \
    --condition=None \
    >/dev/null
done
echo "    OK"

# ---------- create or update the Eventarc trigger ------------------------
trigger_exists() {
  gcloud eventarc triggers describe "$TRIGGER_NAME" \
    --location="$GCP_REGION" >/dev/null 2>&1
}

if trigger_exists; then
  echo "==> Trigger '$TRIGGER_NAME' already exists; updating destination..."
  gcloud eventarc triggers update "$TRIGGER_NAME" \
    --location="$GCP_REGION" \
    --destination-run-service="$INGESTION_SERVICE" \
    --destination-run-region="$GCP_REGION" \
    --destination-run-path="/" \
    --service-account="$SA_INGESTION_EMAIL"
else
  echo "==> Creating trigger '$TRIGGER_NAME' (retrying on IAM propagation delay)..."
  # Eventarc validates bucket access during create using the Eventarc service
  # agent's IAM. We just (re)granted that role, so the first attempt may 403
  # while the binding propagates. Try a few times with backoff.
  attempt=1
  max_attempts=6
  until gcloud eventarc triggers create "$TRIGGER_NAME" \
        --location="$GCP_REGION" \
        --destination-run-service="$INGESTION_SERVICE" \
        --destination-run-region="$GCP_REGION" \
        --destination-run-path="/" \
        --event-filters="type=${EVENT_TYPE}" \
        --event-filters="bucket=${GCS_BUCKET_RAW}" \
        --service-account="$SA_INGESTION_EMAIL"; do
    if (( attempt >= max_attempts )); then
      echo "ERROR: trigger create failed after $attempt attempts." >&2
      echo "       The Eventarc service agent ($EVENTARC_SA) likely still" >&2
      echo "       hasn't gotten roles/eventarc.serviceAgent. Check with:" >&2
      echo "         gcloud projects get-iam-policy $GCP_PROJECT_ID \\" >&2
      echo "           --flatten=bindings --format='value(bindings.role,bindings.members)' \\" >&2
      echo "           | grep eventarc" >&2
      exit 1
    fi
    sleep_s=$(( 15 * attempt ))
    echo "    attempt $attempt failed; sleeping ${sleep_s}s for IAM propagation..."
    sleep "$sleep_s"
    attempt=$(( attempt + 1 ))
  done
fi

# ---------- show what we built -------------------------------------------
echo
echo "==> Trigger details:"
gcloud eventarc triggers describe "$TRIGGER_NAME" \
  --location="$GCP_REGION" \
  --format='yaml(name,eventFilters,destination.cloudRun,serviceAccount,state)'

echo
echo "==> Done."
echo
echo "Smoke test:"
echo "  1. Upload a small PDF to the raw bucket:"
echo "       gcloud storage cp some.pdf gs://${GCS_BUCKET_RAW}/"
echo "  2. Watch the ingestion service logs:"
echo "       gcloud run services logs tail ${INGESTION_SERVICE} --region=${GCP_REGION}"
echo "  3. Confirm a row landed in Postgres:"
echo "       SELECT id, gcs_uri, status, num_chunks FROM documents ORDER BY created_at DESC LIMIT 5;"
echo
echo "Heads up: the very first event after creating an Eventarc trigger can take"
echo "1-2 minutes to start flowing while the underlying Pub/Sub topic propagates."
