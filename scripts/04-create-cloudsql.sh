#!/usr/bin/env bash
#
# 04-create-cloudsql.sh
# Provisions Cloud SQL Postgres for the PDF RAG vector store and installs
# the pgvector extension.
#
# WHAT IT DOES (idempotent):
#   1. Generates strong random passwords for postgres + app user, stores them
#      in Secret Manager. If the secrets already exist, reuses them.
#   2. Creates the Cloud SQL instance:
#        - POSTGRES_16, db-custom-1-3840 (1 vCPU / 3.75GB), 10GB SSD
#        - Public IP, NO authorized networks (only the Cloud SQL Auth Proxy
#          can reach it; proxy uses IAM-authenticated TLS)
#        - SSL enforced (--ssl-mode=ENCRYPTED_ONLY)
#        - Automated backups + point-in-time recovery enabled
#        - Storage auto-increase enabled
#   3. Creates the application database (`ragdb`) and user (`ragapp`).
#   4. Connects via `gcloud sql connect` and runs `CREATE EXTENSION vector`.
#
# PREREQS:
#   - APIs enabled (run 01-enable-apis.sh).
#   - gcloud installed from the GCP website download (NOT Homebrew):
#       https://cloud.google.com/sdk/docs/install
#       The official installer supports `gcloud components install`, which
#       Homebrew-managed gcloud does not.
#   - cloud-sql-proxy gcloud component installed:
#       gcloud components install cloud-sql-proxy
#       (required by `gcloud sql connect` v2; without it, the CREATE
#       EXTENSION step at the end of this script will fail.)
#   - psql on PATH (so `gcloud sql connect` can run the CREATE EXTENSION).
#       macOS:  brew install libpq && brew link --force libpq
#       Or:     brew install postgresql@16
#
# NOTES:
#   - Instance creation typically takes 5-10 minutes. The script will block.
#   - Service accounts already have roles/secretmanager.secretAccessor and
#     roles/cloudsql.client at project level (set in 03-create-service-accounts.sh),
#     so they can read these secrets and connect to this instance.

set -euo pipefail

# ----- CONFIG -------------------------------------------------------------
. ./00-config.sh
# --------------------------------------------------------------------------

echo "==> Project:    $GCP_PROJECT_ID"
echo "==> Region:     $GCP_REGION"
echo "==> Instance:   $CLOUDSQL_INSTANCE  ($CLOUDSQL_TIER, $CLOUDSQL_AVAILABILITY)"
echo "==> Connection: $CLOUDSQL_CONNECTION_NAME"
echo "==> Database:   $DB_NAME"
echo "==> App user:   $DB_USER"
echo

gcloud config set project "$GCP_PROJECT_ID" 

# ---------- helpers -----------------------------------------------------
gen_password() {
  # 32 random base64-ish chars, SIGPIPE-safe (no infinite stream piped to head).
  # Reads a finite 64 random bytes, base64-encodes (~88 chars), strips
  # url-unsafe punctuation, then takes the first 32 via bash substring.
  local chars
  chars="$(LC_ALL=C dd if=/dev/urandom bs=64 count=1 2>/dev/null | base64 | tr -d '/+=\n')"
  if [[ ${#chars} -lt 32 ]]; then
    echo "ERROR: gen_password got only ${#chars} usable chars, expected >=32" >&2
    return 1
  fi
  printf '%s' "${chars:0:32}"
}

ensure_secret_with_password() {
  # Args: secret_name
  # Idempotent in two dimensions:
  #   - creates the secret if missing
  #   - ensures the secret has at least one accessible version (handles the
  #     case where a previous run created the secret but failed before adding
  #     a version, leaving 'describe' succeeding but 'access' failing).
  #
  # Uses explicit error checks throughout instead of relying on `set -e`
  # propagation, which is unreliable in bash 3.2 (default on macOS) when the
  # failing command sits inside a function called as a simple statement.
  local name="$1"

  # Step 1: ensure the secret resource exists.
  if gcloud secrets describe "$name" >/dev/null 2>&1; then
    echo "   - secret '$name' exists."
  else
    echo "   - creating secret '$name'..."
    if ! gcloud secrets create "$name" --replication-policy="automatic"; then
      echo "ERROR: failed to create secret '$name'." >&2
      return 1
    fi
  fi

  # Step 2: ensure the secret has at least one accessible version.
  # Using `access latest` as the probe avoids the filter-warning noise and
  # tests exactly what the rest of the script depends on.
  if gcloud secrets versions access latest --secret="$name" >/dev/null 2>&1; then
    echo "   - '$name' has a usable version, reusing."
    return 0
  fi

  echo "   - '$name' has no usable version, generating and adding one..."
  local pw
  if ! pw="$(gen_password)"; then
    echo "ERROR: gen_password failed for '$name'." >&2
    return 1
  fi
  if [[ -z "$pw" ]]; then
    echo "ERROR: gen_password produced empty output for '$name'." >&2
    return 1
  fi
  if ! printf '%s' "$pw" | gcloud secrets versions add "$name" --data-file=-; then
    echo "ERROR: failed to add a version to secret '$name'." >&2
    return 1
  fi
}

read_secret() {
  local name="$1"
  if ! gcloud secrets versions access latest --secret="$name" 2>/dev/null; then
    echo "ERROR: failed to read secret '$name'." >&2
    echo "  Things to check:" >&2
    echo "  - Does your gcloud account have roles/secretmanager.secretAccessor on this project?" >&2
    echo "      gcloud projects add-iam-policy-binding $GCP_PROJECT_ID \\" >&2
    echo "        --member=user:\$(gcloud config get-value account) \\" >&2
    echo "        --role=roles/secretmanager.secretAccessor" >&2
    echo "  - Is the secret actually populated? Inspect with:" >&2
    echo "      gcloud secrets versions list $name" >&2
    return 1
  fi
}

# ---------- 1. passwords in Secret Manager -------------------------------
echo "==> Secret Manager: ensuring DB passwords exist DB_ROOT"
ensure_secret_with_password "$SECRET_DB_ROOT_PASSWORD"
echo "==> Secret Manager: ensuring DB passwords exist DB_APP"
ensure_secret_with_password "$SECRET_DB_APP_PASSWORD"

echo "==> Secret Manager: reading secret"
ROOT_PASSWORD="$(read_secret "$SECRET_DB_ROOT_PASSWORD")"
APP_PASSWORD="$(read_secret "$SECRET_DB_APP_PASSWORD")"

# ---------- 2. Cloud SQL instance ---------------------------------------
echo
echo "==> Cloud SQL instance"
if gcloud sql instances describe "$CLOUDSQL_INSTANCE" >/dev/null 2>&1; then
  echo "   - instance '$CLOUDSQL_INSTANCE' already exists, skipping create."
else
  echo "   - creating instance '$CLOUDSQL_INSTANCE' (this takes 5-10 minutes)..."
  # --edition=ENTERPRISE is required to use db-custom-* tiers. Without it,
  # the project may default to ENTERPRISE_PLUS, which only accepts predefined
  # db-perf-optimized-N-* tiers (much more expensive). Enterprise is correct
  # for prototypes and small production workloads.
  gcloud sql instances create "$CLOUDSQL_INSTANCE" \
    --edition=ENTERPRISE \
    --database-version="$CLOUDSQL_PG_VERSION" \
    --tier="$CLOUDSQL_TIER" \
    --region="$GCP_REGION" \
    --availability-type="$CLOUDSQL_AVAILABILITY" \
    --storage-type=SSD \
    --storage-size="$CLOUDSQL_DISK_SIZE_GB" \
    --storage-auto-increase \
    --backup \
    --backup-start-time=02:00 \
    --enable-point-in-time-recovery \
    --retained-backups-count=7 \
    --retained-transaction-log-days=7 \
    --root-password="$ROOT_PASSWORD" \
    --ssl-mode=ENCRYPTED_ONLY \
    --no-deletion-protection
  # ^ deletion-protection off for prototype — flip on for prod with:
  #   gcloud sql instances patch "$CLOUDSQL_INSTANCE" --deletion-protection
fi

# Belt-and-braces: re-set the postgres password in case the secret was
# rotated since instance creation.
echo "   - syncing postgres root password from Secret Manager..."
gcloud sql users set-password postgres \
  --instance="$CLOUDSQL_INSTANCE" \
  --password="$ROOT_PASSWORD" >/dev/null

# ---------- 3. database + app user --------------------------------------
echo
echo "==> Database + app user"

if gcloud sql databases describe "$DB_NAME" --instance="$CLOUDSQL_INSTANCE" >/dev/null 2>&1; then
  echo "   - database '$DB_NAME' exists, skipping."
else
  echo "   - creating database '$DB_NAME'..."
  gcloud sql databases create "$DB_NAME" --instance="$CLOUDSQL_INSTANCE"
fi

if gcloud sql users list --instance="$CLOUDSQL_INSTANCE" \
     --format="value(name)" | grep -qx "$DB_USER"; then
  echo "   - user '$DB_USER' exists, syncing password from Secret Manager."
  gcloud sql users set-password "$DB_USER" \
    --instance="$CLOUDSQL_INSTANCE" \
    --password="$APP_PASSWORD" >/dev/null
else
  echo "   - creating user '$DB_USER'..."
  gcloud sql users create "$DB_USER" \
    --instance="$CLOUDSQL_INSTANCE" \
    --password="$APP_PASSWORD"
fi

# ---------- 4. pgvector extension ---------------------------------------
echo
echo "==> Installing pgvector extension"

print_manual_extension_instructions() {
  cat >&2 <<EOF

  Skipping in-script CREATE EXTENSION. The DB itself is fully provisioned.
  Run this ONE-TIME setup yourself (any of the following works):

  Option A) Install the gcloud component (if you installed gcloud via the
  official installer):
      gcloud components install cloud-sql-proxy
      ./04-create-cloudsql.sh   # re-run; the rest is idempotent

  Option B) Homebrew-managed gcloud — install via brew:
      brew install google-cloud-sql-proxy
      ./04-create-cloudsql.sh

  Option C) Cloud Shell (browser, no local install needed). Open Cloud Shell
  on the project, then:
      gcloud sql connect $CLOUDSQL_INSTANCE --user=postgres --database=$DB_NAME
      # paste at the postgres prompt:
      CREATE EXTENSION IF NOT EXISTS vector;
      GRANT ALL ON SCHEMA public TO $DB_USER;
      \\q

EOF
}

run_extension_sql() {
  PGPASSWORD="$ROOT_PASSWORD" gcloud sql connect "$CLOUDSQL_INSTANCE" \
    --user=postgres --database="$DB_NAME" --quiet <<SQL
CREATE EXTENSION IF NOT EXISTS vector;
-- Grant schema usage to the app user so it can create tables / use vector.
GRANT ALL ON SCHEMA public TO ${DB_USER};
SELECT extname, extversion FROM pg_extension WHERE extname='vector';
SQL
}

if ! command -v psql >/dev/null 2>&1; then
  echo "   - psql not found on PATH (needed by 'gcloud sql connect')."
  echo "     macOS:  brew install libpq && brew link --force libpq"
  print_manual_extension_instructions
else
  echo "   - connecting via 'gcloud sql connect' and running CREATE EXTENSION..."
  if ! run_extension_sql; then
    echo
    echo "   - 'gcloud sql connect' failed. Most common cause: the cloud-sql-proxy"
    echo "     gcloud component is not installed (required for connect v2)."
    echo "     Attempting to install it now..."
    if gcloud components install cloud-sql-proxy --quiet 2>&1 | tee /tmp/gcc-install.log \
         | grep -q "Update done"; then
      echo "   - component installed; retrying CREATE EXTENSION..."
      if ! run_extension_sql; then
        echo "   - retry failed."
        print_manual_extension_instructions
      fi
    else
      echo "   - auto-install did not complete (often the case on Homebrew gcloud)."
      print_manual_extension_instructions
    fi
  fi
fi

# ---------- summary -----------------------------------------------------
cat <<EOF

Done. Summary:
  Connection name (for Cloud Run --add-cloudsql-instances):
    $CLOUDSQL_CONNECTION_NAME

  Database:        $DB_NAME
  App user:        $DB_USER
  Root password:   stored in Secret Manager as '$SECRET_DB_ROOT_PASSWORD'
  App password:    stored in Secret Manager as '$SECRET_DB_APP_PASSWORD'

  To inspect a password manually:
    gcloud secrets versions access latest --secret=$SECRET_DB_APP_PASSWORD

Next steps:
  - Create the chunks table with a vector column + HNSW index.
  - Build + deploy the Cloud Run ingestion service:
      gcloud run deploy ingestion \\
        --service-account=$SA_INGESTION_EMAIL \\
        --add-cloudsql-instances=$CLOUDSQL_CONNECTION_NAME \\
        --set-secrets=DB_PASSWORD=$SECRET_DB_APP_PASSWORD:latest \\
        ...
EOF
