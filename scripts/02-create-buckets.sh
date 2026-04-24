#!/usr/bin/env bash
#
# 02-create-buckets.sh
# Creates the two GCS buckets used by the PDF RAG pipeline:
#   - <project>-raw        : landing zone for uploaded PDFs. VERSIONED.
#   - <project>-processed  : extracted text / chunks / metadata. Not versioned.
#
# Security defaults applied to both:
#   - Uniform bucket-level access (IAM only, no per-object ACLs)
#   - Public access prevention (enforced)
#   - Standard storage class
#
# Cost control on the raw bucket:
#   - Lifecycle rule deletes noncurrent versions after RAW_NONCURRENT_RETENTION_DAYS
#
# Safe to re-run: bucket creation is skipped if it already exists; all other
# settings are applied idempotently.

set -euo pipefail

# ----- CONFIG -------------------------------------------------------------
. ./00-config.sh
# --------------------------------------------------------------------------

echo "==> Project:  $GCP_PROJECT_ID"
echo "==> Region:   $GCP_REGION"
echo "==> Raw:      gs://$GCS_BUCKET_RAW (versioned)"
echo "==> Processed:gs://$GCS_BUCKET_PROCESSED"
echo

gcloud config set project "$GCP_PROJECT_ID" >/dev/null

# ---------- helper: create a bucket if it doesn't already exist ----------
create_bucket_if_missing() {
  local bucket="$1"
  if gcloud storage buckets describe "gs://${bucket}" >/dev/null 2>&1; then
    echo "   - gs://${bucket} already exists, skipping create."
  else
    echo "   - creating gs://${bucket} in ${GCP_REGION}..."
    gcloud storage buckets create "gs://${bucket}" \
      --project="$GCP_PROJECT_ID" \
      --location="$GCP_REGION" \
      --default-storage-class=STANDARD \
      --uniform-bucket-level-access \
      --public-access-prevention
  fi
}

# ---------- RAW BUCKET ---------------------------------------------------
echo "==> Raw bucket"
create_bucket_if_missing "$GCS_BUCKET_RAW"

echo "   - enabling object versioning on gs://${GCS_BUCKET_RAW}"
gcloud storage buckets update "gs://${GCS_BUCKET_RAW}" --versioning

# Lifecycle: delete noncurrent versions older than N days to cap cost.
LIFECYCLE_JSON="$(mktemp)"
trap 'rm -f "$LIFECYCLE_JSON"' EXIT
cat >"$LIFECYCLE_JSON" <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": { "type": "Delete" },
        "condition": {
          "daysSinceNoncurrentTime": ${RAW_NONCURRENT_RETENTION_DAYS},
          "numNewerVersions": 1
        }
      }
    ]
  }
}
EOF
echo "   - applying lifecycle: delete noncurrent versions after ${RAW_NONCURRENT_RETENTION_DAYS} days"
gcloud storage buckets update "gs://${GCS_BUCKET_RAW}" \
  --lifecycle-file="$LIFECYCLE_JSON"

# ---------- PROCESSED BUCKET --------------------------------------------
echo
echo "==> Processed bucket"
create_bucket_if_missing "$GCS_BUCKET_PROCESSED"

# Belt-and-braces: make sure versioning is OFF on processed (it's the default,
# but in case an older run flipped it on).
echo "   - ensuring versioning is OFF on gs://${GCS_BUCKET_PROCESSED}"
gcloud storage buckets update "gs://${GCS_BUCKET_PROCESSED}" --no-versioning

# ---------- VERIFY -------------------------------------------------------
echo
echo "==> Verification"
for b in "$GCS_BUCKET_RAW" "$GCS_BUCKET_PROCESSED"; do
  echo
  echo "--- gs://${b} ---"
  gcloud storage buckets describe "gs://${b}" \
    --format="yaml(name, location, storageClass, versioning, iamConfiguration.uniformBucketLevelAccess.enabled, iamConfiguration.publicAccessPrevention, lifecycle)"
done

echo
echo "Done. Next steps:"
echo "  - Create service accounts for ingestion + query (least-privilege)."
echo "  - Provision Cloud SQL (Postgres) with the pgvector extension."
echo "  - Wire Eventarc: gs://${GCS_BUCKET_RAW} object-finalized -> Cloud Run ingestion service."
