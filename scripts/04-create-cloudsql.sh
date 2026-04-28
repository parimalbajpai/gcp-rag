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

gcloud config set project "$GCP_PROJECT_ID" >/dev/null

# ---------- helpers -----------------------------------------------------
gen_password() {
  # 32 url-safe-ish random chars, no padding/equals/slashes that complicate URIs.
  LC_ALL=C tr -dc 'A-Za-z0-9_-' </dev/urandom | head -c 32
}

ensure_secret_with_password() {
  # Args: secret_name
  # Creates the secret if missing, generates a fresh password, adds it as
  # version 1. If the secret already exists, leaves it alone.
  local name="$1"
  if gcloud secrets describe "$name" >/dev/null 2>&1; then
    echo "   - secret '$name' exists, reusing."
  else
    echo "   - creating secret '$name' and generating password..."
    gcloud secrets create "$name" --replication-policy="automatic" >/dev/null
    local pw; pw="$(gen_password)"
    printf '%s' "$pw" | gcloud secrets versions add "$name" --data-file=- >/dev/null
  fi
}

read_secret() {
  gcloud secrets versions access latest --secret="$1"
}

# ---------- 1. passwords in Secret Manager -------------------------------
echo "==> Secret Manager: ensuring DB passwords exist"
ensure_secret_with_password "$SECRET_DB_ROOT_PASSWORD"
ensure_secret_with_password "$SECRET_DB_APP_PASSWORD"

ROOT_PASSWORD="$(read_secret "$SECRET_DB_ROOT_PASSWORD")"
APP_PASSWORD="$(read_secret "$SECRET_DB_APP_PASSWORD")"

# ---------- 2. Cloud SQL instance ---------------------------------------
echo
echo "==> Cloud SQL instance"
if gcloud sql instances describe "$CLOUDSQL_INSTANCE" >/dev/null 2>&1; then
  echo "   - instance '$CLOUDSQL_INSTANCE' already exists, skipping create."
else
  echo "   - creating instance '$CLOUDSQL_INSTANCE' (this takes 5-10 minutes)..."
  gcloud sql instances create "$CLOUDSQL_INSTANCE" \
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

if ! command -v psql >/dev/null 2>&1; then
  cat <<EOF
   - psql not found on PATH. Skipping CREATE EXTENSION.
     Install psql and re-run this script, OR run this once manually:

     PGPASSWORD='<root-pw-from-secret-manager>' \\
       gcloud sql connect $CLOUDSQL_INSTANCE \\
         --user=postgres --database=$DB_NAME --quiet \\
         <<<'CREATE EXTENSION IF NOT EXISTS vector;'

     macOS install: brew install libpq && brew link --force libpq
EOF
else
  # gcloud sql connect auto-whitelists this machine's public IP for ~5 min.
  echo "   - connecting via 'gcloud sql connect' and running CREATE EXTENSION..."
  PGPASSWORD="$ROOT_PASSWORD" gcloud sql connect "$CLOUDSQL_INSTANCE" \
    --user=postgres --database="$DB_NAME" --quiet <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
-- Grant schema usage to the app user so it can create tables / use vector.
GRANT ALL ON SCHEMA public TO ragapp;
SELECT extname, extversion FROM pg_extension WHERE extname='vector';
SQL
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
