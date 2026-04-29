#!/usr/bin/env bash
#
# 05-create-schema.sh
# Creates the application schema in the Cloud SQL Postgres database.
#
# TABLES
#   documents : one row per ingested PDF (status, metadata, GCS URI)
#   chunks    : many rows per document, each with text + a vector(EMBEDDING_DIM)
#               embedding for similarity search.
#
# INDEXES
#   chunks_embedding_hnsw_idx : HNSW vector index on chunks.embedding using
#                               cosine distance. Right default for normalized
#                               Vertex AI embeddings. No training needed.
#   chunks_content_fts_idx    : GIN full-text index on chunks.content. Enables
#                               hybrid retrieval (vector + keyword) later.
#   plus B-tree supporting indexes on FK / status columns.
#
# IDEMPOTENT
#   All DDL uses `IF NOT EXISTS`. Re-runs are safe and produce no churn.
#
# CONNECTS AS THE APP USER
#   Tables are owned by `ragapp` (not postgres root). The two service accounts
#   already share this DB user via Secret Manager, so they get full access to
#   the schema they'll use.
#
# PREREQS (same as 04-create-cloudsql.sh)
#   - APIs enabled.
#   - gcloud installed from official GCP download (NOT Homebrew).
#   - cloud-sql-proxy gcloud component:  gcloud components install cloud-sql-proxy
#   - psql on PATH:                       brew install libpq && brew link --force libpq

set -euo pipefail

# ----- CONFIG -------------------------------------------------------------
. ./00-config.sh
# --------------------------------------------------------------------------

echo "==> Project:  $GCP_PROJECT_ID"
echo "==> Instance: $CLOUDSQL_INSTANCE"
echo "==> Database: $DB_NAME"
echo "==> App user: $DB_USER"
echo "==> Embedding dimension: $EMBEDDING_DIM"
echo

gcloud config set project "$GCP_PROJECT_ID" >/dev/null

# ---------- read app-user password from Secret Manager -------------------
echo "==> Reading app-user password from Secret Manager..."
if ! APP_PASSWORD="$(gcloud secrets versions access latest --secret="$SECRET_DB_APP_PASSWORD")"; then
  echo "ERROR: failed to read secret '$SECRET_DB_APP_PASSWORD'." >&2
  echo "  Make sure 04-create-cloudsql.sh has been run successfully." >&2
  exit 1
fi
if [[ -z "$APP_PASSWORD" ]]; then
  echo "ERROR: secret '$SECRET_DB_APP_PASSWORD' returned an empty value." >&2
  exit 1
fi

# ---------- preflight: connect tools -------------------------------------
if ! command -v psql >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: psql not found on PATH (needed by 'gcloud sql connect').
  macOS:  brew install libpq && brew link --force libpq
EOF
  exit 1
fi

# Application Default Credentials: required by cloud-sql-proxy v2.
# `gcloud auth login` does NOT set these up — they are separate.
ADC_FILE="${HOME}/.config/gcloud/application_default_credentials.json"
if [[ ! -f "$ADC_FILE" ]]; then
  cat >&2 <<EOF
ERROR: Application Default Credentials (ADC) not found at:
  $ADC_FILE

cloud-sql-proxy v2 (used by 'gcloud sql connect') reads ADC, not your regular
'gcloud auth login' credentials. This is a one-time setup. Run:

  gcloud auth application-default login

then re-run this script.
EOF
  exit 1
fi

# ---------- start cloud-sql-proxy ----------------------------------------
# We drive cloud-sql-proxy directly instead of using `gcloud sql connect`.
# Reason: `gcloud sql connect` v2 doesn't reliably pass PGPASSWORD through
# to psql and may drop to an interactive prompt.
PROXY_PORT="${PROXY_PORT:-15432}"
PROXY_PID=""

stop_proxy() {
  if [[ -n "$PROXY_PID" ]] && kill -0 "$PROXY_PID" 2>/dev/null; then
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
  fi
  PROXY_PID=""
}
trap stop_proxy EXIT

if ! command -v cloud-sql-proxy >/dev/null 2>&1; then
  echo "ERROR: cloud-sql-proxy not on PATH." >&2
  echo "  Install: gcloud components install cloud-sql-proxy" >&2
  exit 1
fi

echo "==> Starting cloud-sql-proxy on 127.0.0.1:$PROXY_PORT..."
cloud-sql-proxy "$CLOUDSQL_CONNECTION_NAME" --port "$PROXY_PORT" --quiet \
  >/tmp/cloud-sql-proxy.log 2>&1 &
PROXY_PID=$!

# Wait up to ~15s for the proxy to accept connections.
for _ in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/"$PROXY_PORT") 2>/dev/null; then
    exec 3<&- 3>&-
    break
  fi
  sleep 0.5
done
if ! (exec 3<>/dev/tcp/127.0.0.1/"$PROXY_PORT") 2>/dev/null; then
  echo "ERROR: cloud-sql-proxy didn't become ready. See /tmp/cloud-sql-proxy.log" >&2
  exit 1
fi
exec 3<&- 3>&- || true

# ---------- apply schema -------------------------------------------------
echo "==> Applying schema..."
PGPASSWORD="$APP_PASSWORD" psql \
  --host=127.0.0.1 --port="$PROXY_PORT" \
  --username="$DB_USER" --dbname="$DB_NAME" \
  --no-password \
  -v ON_ERROR_STOP=1 <<SQL
-- Defensive: ensure pgvector exists. (04-create-cloudsql.sh already did this.)
-- We only run as ragapp here, who has CREATE on schema public; CREATE EXTENSION
-- needs superuser, so we don't repeat it. Fail loudly if it's missing.
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='vector') THEN
    RAISE EXCEPTION 'pgvector extension not installed. Re-run 04-create-cloudsql.sh as postgres.';
  END IF;
END
\$\$;

-- ---- documents ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS documents (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  gcs_uri       text        NOT NULL UNIQUE,         -- gs://<bucket>/<object>
  filename      text        NOT NULL,
  content_hash  text,                                 -- sha256 of bytes (optional dedupe)
  size_bytes    bigint,
  num_pages     int,
  status        text        NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','processing','completed','failed')),
  error         text,
  metadata      jsonb       NOT NULL DEFAULT '{}'::jsonb,
  uploaded_at   timestamptz NOT NULL DEFAULT now(),
  processed_at  timestamptz
);

CREATE INDEX IF NOT EXISTS documents_status_idx
  ON documents (status);
CREATE INDEX IF NOT EXISTS documents_uploaded_at_idx
  ON documents (uploaded_at DESC);
CREATE INDEX IF NOT EXISTS documents_content_hash_idx
  ON documents (content_hash) WHERE content_hash IS NOT NULL;

-- ---- chunks ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS chunks (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id   uuid        NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  chunk_index   int         NOT NULL,         -- position within the document
  page_number   int,                          -- source page (if known)
  content       text        NOT NULL,
  token_count   int,
  embedding     vector(${EMBEDDING_DIM}) NOT NULL,
  metadata      jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (document_id, chunk_index)
);

CREATE INDEX IF NOT EXISTS chunks_document_id_idx
  ON chunks (document_id);

-- HNSW index on the embedding for fast cosine-similarity ANN search.
-- m / ef_construction are reasonable defaults; bump for higher recall at
-- the cost of slower index build and slightly more memory:
--   WITH (m = 24, ef_construction = 128)
-- Query-side recall is tuned with: SET hnsw.ef_search = 100;
CREATE INDEX IF NOT EXISTS chunks_embedding_hnsw_idx
  ON chunks USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- Full-text search index on content. Pairs with vector search for hybrid
-- retrieval (e.g., reciprocal-rank fusion of BM25 + ANN scores).
CREATE INDEX IF NOT EXISTS chunks_content_fts_idx
  ON chunks USING GIN (to_tsvector('english', content));

-- ---- ingestion bookkeeping (optional but cheap) ------------------------
-- One row per processing attempt. Useful for retries and debugging.
CREATE TABLE IF NOT EXISTS ingestion_events (
  id            bigserial   PRIMARY KEY,
  document_id   uuid        REFERENCES documents(id) ON DELETE CASCADE,
  gcs_uri       text        NOT NULL,
  event_type    text        NOT NULL,          -- 'started','completed','failed'
  message       text,
  payload       jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ingestion_events_document_id_idx
  ON ingestion_events (document_id);
CREATE INDEX IF NOT EXISTS ingestion_events_created_at_idx
  ON ingestion_events (created_at DESC);

-- ---- verify ------------------------------------------------------------
\echo '--- tables ---'
SELECT tablename, tableowner
  FROM pg_tables
 WHERE schemaname = 'public'
 ORDER BY tablename;

\echo '--- indexes on chunks ---'
SELECT indexname, indexdef
  FROM pg_indexes
 WHERE schemaname = 'public' AND tablename = 'chunks'
 ORDER BY indexname;

\echo '--- pgvector ---'
SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';
SQL

echo
echo "Done. Schema is ready."
echo
echo "Quick sanity check from psql / gcloud sql connect:"
echo "  -- Insert a fake row to verify dimensions:"
echo "  INSERT INTO documents (gcs_uri, filename) VALUES ('gs://test/test.pdf','test.pdf');"
echo "  INSERT INTO chunks (document_id, chunk_index, content, embedding)"
echo "  SELECT id, 0, 'hello', array_fill(0.1::float, ARRAY[${EMBEDDING_DIM}])::vector"
echo "    FROM documents WHERE gcs_uri='gs://test/test.pdf';"
echo "  SELECT id, chunk_index FROM chunks LIMIT 1;"
echo "  -- Clean up:"
echo "  DELETE FROM documents WHERE gcs_uri='gs://test/test.pdf';"
echo
echo "Next: scaffold the Cloud Run ingestion service that writes into these tables."
