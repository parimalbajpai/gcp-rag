#!/usr/bin/env bash
#
# 01-enable-apis.sh
# Enables the GCP APIs needed for the PDF RAG + Chat stack.
#
# Prereqs:
#   - gcloud CLI installed:  https://cloud.google.com/sdk/docs/install
#   - Authenticated:         gcloud auth login
#   - Billing linked to the project (enabling most APIs requires billing).
#
# Usage:
#   1. Set PROJECT_ID below (or export it before running).
#   2. chmod +x 01-enable-apis.sh
#   3. ./01-enable-apis.sh
#
# Safe to re-run: `services enable` is idempotent.

set -euo pipefail

# ----- CONFIG -------------------------------------------------------------
. ./00-config.sh
PROJECT_ID=$GCP_PROJECT_ID
# --------------------------------------------------------------------------

if [[ "$PROJECT_ID" == "REPLACE_WITH_YOUR_PROJECT_ID" ]]; then
  echo "ERROR: Set PROJECT_ID at the top of the script (or export it)." >&2
  exit 1
fi

echo "==> Using project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" 

echo "**> after gcloud config set project"

# Sanity: confirm billing is enabled. APIs like Vertex AI will fail to enable otherwise.
# Uses the GA `gcloud billing` surface (no `beta` component required).
# If the command itself fails (permissions, old gcloud, etc.), we warn and continue
# rather than block — the real API enablement below will surface a clear error.
BILLING_ENABLED="$(gcloud billing projects describe "$PROJECT_ID" \
  --format="value(billingEnabled)" 2>/dev/null || true)"
BILLING_ENABLED="${BILLING_ENABLED:-unknown}"

if [[ "$BILLING_ENABLED" != "True" ]]; then
  echo "WARNING: Billing not confirmed enabled on $PROJECT_ID (got: $BILLING_ENABLED)."
  echo "         If this is wrong, you may lack 'billing.resourceAssociations.list' permission."
  echo "         Link/verify a billing account here:"
  echo "         https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
  read -r -p "Continue anyway? [y/N] " yn
  [[ "$yn" == "y" || "$yn" == "Y" ]] || exit 1
fi

echo "**> Billing check passed (got: $BILLING_ENABLED). Proceeding with API enablement..."

# Core APIs for the RAG + Chat stack.
APIS=(
  # Storage & data
  "storage.googleapis.com"          # Cloud Storage (PDF buckets)
  "sqladmin.googleapis.com"         # Cloud SQL (pgvector host)

  # Compute
  "run.googleapis.com"              # Cloud Run (ingestion + query services)
  "artifactregistry.googleapis.com" # Container images for Cloud Run

  # Eventing
  "eventarc.googleapis.com"         # GCS -> Pub/Sub -> Cloud Run triggers
  "pubsub.googleapis.com"           # Pub/Sub (under the hood for Eventarc)

  # AI
  "aiplatform.googleapis.com"       # Vertex AI (Gemini + embeddings)
  "documentai.googleapis.com"       # Document AI (OCR / Layout Parser)

  # Platform basics
  "secretmanager.googleapis.com"    # Secret Manager (DB creds, API keys)
  "iam.googleapis.com"              # IAM policy management
  "cloudbuild.googleapis.com"       # Required to deploy Cloud Run from source
  "cloudresourcemanager.googleapis.com" # Project-level admin calls
  "logging.googleapis.com"          # Cloud Logging (usually on, enabling is cheap)
  "monitoring.googleapis.com"       # Cloud Monitoring
  "compute.googleapis.com"          # Needed for networking used by Cloud SQL/VPC
)

echo "==> Enabling ${#APIS[@]} APIs (this can take 1-2 minutes)..."
# Enable in a single call — faster and transactional-ish.
gcloud services enable "${APIS[@]}" --project "$PROJECT_ID"

echo
echo "==> Verifying enabled state:"
gcloud services list --enabled --project "$PROJECT_ID" \
  --filter="config.name:($(IFS='|'; echo "${APIS[*]}"))" \
  --format="table(config.name, config.title)"

echo
echo "Done. Next steps:"
echo "  - Create service accounts for ingestion + query (principle of least privilege)."
echo "  - Create GCS buckets (raw + processed) with versioning."
echo "  - Provision Cloud SQL (Postgres) with the pgvector extension."
echo "  - Scaffold Terraform to capture all of the above as code."
