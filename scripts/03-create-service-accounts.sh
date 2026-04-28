#!/usr/bin/env bash
#
# 03-create-service-accounts.sh
# Creates two least-privilege service accounts for the PDF RAG stack and
# binds them to the minimum set of roles they actually need.
#
# SERVICE ACCOUNTS
#   ingestion-sa: runs the Cloud Run service that processes uploaded PDFs.
#     Reads from raw bucket, writes to processed bucket, calls Document AI
#     and Vertex AI (embeddings), writes vectors to Cloud SQL.
#
#   query-sa: runs the Cloud Run service that serves chat queries.
#     Calls Vertex AI (embeddings + Gemini), reads vectors from Cloud SQL.
#     Does NOT have access to the raw bucket by design — if the UI needs
#     to link back to source PDFs, generate signed URLs via the ingestion
#     service or a separate read-only SA.
#
# BINDING STRATEGY
#   - GCS: bucket-level bindings (tightest). Requires buckets to exist
#     (run 02-create-buckets.sh first).
#   - Vertex AI / Document AI / Cloud SQL / Secret Manager: project-level
#     (these APIs don't offer useful resource-level binding for our use).
#   - Logging / Monitoring: project-level (required for Cloud Run custom SAs).
#
# Safe to re-run. `create` is guarded; `add-iam-policy-binding` is idempotent.

set -euo pipefail

# ----- CONFIG -------------------------------------------------------------
. ./00-config.sh
# --------------------------------------------------------------------------

echo "==> Project: $GCP_PROJECT_ID"
echo "==> Ingestion SA: $SA_INGESTION_EMAIL"
echo "==> Query SA:     $SA_QUERY_EMAIL"
echo

gcloud config set project "$GCP_PROJECT_ID" >/dev/null

# ---------- helpers -----------------------------------------------------
create_sa_if_missing() {
  local sa_id="$1"
  local display_name="$2"
  if gcloud iam service-accounts describe \
      "${sa_id}@${GCP_PROJECT_ID}.iam.gserviceaccount.com" >/dev/null 2>&1; then
    echo "   - ${sa_id} already exists, skipping create."
  else
    echo "   - creating ${sa_id}..."
    gcloud iam service-accounts create "$sa_id" \
      --display-name="$display_name" \
      --project="$GCP_PROJECT_ID"
  fi
}

bind_project_role() {
  local sa_email="$1"
  local role="$2"
  echo "   - project binding: ${sa_email}  ->  ${role}"
  gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:${sa_email}" \
    --role="$role" \
    --condition=None \
    --quiet >/dev/null
}

bind_bucket_role() {
  local bucket="$1"
  local sa_email="$2"
  local role="$3"
  echo "   - bucket binding: gs://${bucket}  ${sa_email}  ->  ${role}"
  gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
    --member="serviceAccount:${sa_email}" \
    --role="$role" >/dev/null
}

# ---------- create SAs --------------------------------------------------
echo "==> Service accounts"
create_sa_if_missing "$SA_INGESTION_ID" "PDF RAG - Ingestion (Cloud Run)"
create_sa_if_missing "$SA_QUERY_ID"     "PDF RAG - Query (Cloud Run)"

# ---------- ingestion-sa bindings ---------------------------------------
echo
echo "==> Ingestion SA roles"

# GCS: read raw, read+write processed (bucket-level only).
bind_bucket_role "$GCS_BUCKET_RAW"       "$SA_INGESTION_EMAIL" "roles/storage.objectViewer"
bind_bucket_role "$GCS_BUCKET_PROCESSED" "$SA_INGESTION_EMAIL" "roles/storage.objectUser"

# APIs the ingestion pipeline calls.
bind_project_role "$SA_INGESTION_EMAIL" "roles/documentai.apiUser"
bind_project_role "$SA_INGESTION_EMAIL" "roles/aiplatform.user"

# Vector store + secrets.
bind_project_role "$SA_INGESTION_EMAIL" "roles/cloudsql.client"
bind_project_role "$SA_INGESTION_EMAIL" "roles/secretmanager.secretAccessor"

# Eventarc -> Cloud Run trigger plumbing.
bind_project_role "$SA_INGESTION_EMAIL" "roles/eventarc.eventReceiver"
bind_project_role "$SA_INGESTION_EMAIL" "roles/run.invoker"

# Cloud Run runtime essentials (needed when NOT using the default compute SA).
bind_project_role "$SA_INGESTION_EMAIL" "roles/logging.logWriter"
bind_project_role "$SA_INGESTION_EMAIL" "roles/monitoring.metricWriter"
bind_project_role "$SA_INGESTION_EMAIL" "roles/cloudtrace.agent"

# ---------- query-sa bindings -------------------------------------------
echo
echo "==> Query SA roles"

# No GCS access by default — query path only touches vectors + Gemini.

# APIs the query service calls.
bind_project_role "$SA_QUERY_EMAIL" "roles/aiplatform.user"

# Vector store + secrets.
bind_project_role "$SA_QUERY_EMAIL" "roles/cloudsql.client"
bind_project_role "$SA_QUERY_EMAIL" "roles/secretmanager.secretAccessor"

# Cloud Run runtime essentials.
bind_project_role "$SA_QUERY_EMAIL" "roles/logging.logWriter"
bind_project_role "$SA_QUERY_EMAIL" "roles/monitoring.metricWriter"
bind_project_role "$SA_QUERY_EMAIL" "roles/cloudtrace.agent"

# ---------- verify -------------------------------------------------------
echo
echo "==> Verification"
for sa in "$SA_INGESTION_EMAIL" "$SA_QUERY_EMAIL"; do
  echo
  echo "--- Project-level roles for ${sa} ---"
  gcloud projects get-iam-policy "$GCP_PROJECT_ID" \
    --flatten="bindings[].members" \
    --format="table(bindings.role)" \
    --filter="bindings.members:${sa}"
done

# `gcloud storage buckets get-iam-policy` does NOT accept --flatten/--filter
# (unlike `gcloud projects get-iam-policy`). Dump the full policy as YAML and
# grep for our SAs — portable across gcloud versions.
print_bucket_iam_for_sas() {
  local bucket="$1"
  echo
  echo "--- Bucket IAM: gs://${bucket} (lines mentioning our SAs) ---"
  local policy
  policy="$(gcloud storage buckets get-iam-policy "gs://${bucket}" --format=yaml)"
  # Show each role line and its following members block, but only SA-related members.
  # Simple grep with context is usually enough to eyeball.
  echo "$policy" | grep -E -B1 -A0 "(${SA_INGESTION_ID}|${SA_QUERY_ID})@" || {
    echo "(no bindings found for ingestion-sa or query-sa on this bucket)"
  }
}

print_bucket_iam_for_sas "$GCS_BUCKET_RAW"
print_bucket_iam_for_sas "$GCS_BUCKET_PROCESSED"

echo
echo "Done. Next steps:"
echo "  - Provision Cloud SQL (Postgres) with the pgvector extension."
echo "  - Create secrets for DB creds and wire them up."
echo "  - Build + deploy Cloud Run services using --service-account=<sa email above>."
