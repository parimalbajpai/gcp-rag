"""FastAPI HTTP entry point for the ingestion service.

Two routes:
  GET  /healthz           - Cloud Run readiness check
  POST /                  - Eventarc -> Cloud Run (google.cloud.storage.object.v1.finalized)

Eventarc delivers GCS finalize events as a CloudEvent. Cloud Run wraps it as
an HTTP POST with these headers and a JSON body:
    ce-id, ce-type, ce-source, ce-subject, ce-time, ...
    body: {"bucket": "...", "name": "...", ...}

We:
  - Filter to PDFs only (objects ending in .pdf, case-insensitive).
  - Filter to the configured raw bucket only (defense in depth).
  - Run the synchronous pipeline. Cloud Run holds the connection open until
    we return; on 5xx, Eventarc retries with backoff.
"""
from __future__ import annotations

import logging
import os

from fastapi import FastAPI, HTTPException, Request

from .pipeline import ingest_pdf
from .settings import get_settings

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("ingestion")

app = FastAPI(title="pdf-rag-ingestion", version="0.1.0")


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True}


@app.post("/")
async def handle_event(request: Request) -> dict:
    headers = request.headers
    ce_type = headers.get("ce-type", "")
    ce_subject = headers.get("ce-subject", "")
    ce_id = headers.get("ce-id", "")

    # Pub/Sub-via-Eventarc would be 'google.cloud.pubsub.topic.v1.messagePublished';
    # direct GCS Eventarc trigger is 'google.cloud.storage.object.v1.finalized'.
    # We only care about object-finalize.
    if ce_type and ce_type != "google.cloud.storage.object.v1.finalized":
        log.info("ignoring ce-type=%s id=%s", ce_type, ce_id)
        return {"skipped": True, "reason": f"unsupported ce-type {ce_type}"}

    body = await request.json()
    bucket = body.get("bucket")
    name = body.get("name")
    if not bucket or not name:
        log.warning("malformed event id=%s subject=%s body keys=%s", ce_id, ce_subject, list(body))
        raise HTTPException(status_code=400, detail="missing bucket or name")

    s = get_settings()
    raw_bucket = os.environ.get("RAW_BUCKET", "")
    if raw_bucket and bucket != raw_bucket:
        log.info("ignoring object outside raw bucket: %s/%s", bucket, name)
        return {"skipped": True, "reason": "wrong bucket"}

    if not name.lower().endswith(".pdf"):
        log.info("ignoring non-pdf object: %s/%s", bucket, name)
        return {"skipped": True, "reason": "not a pdf"}

    log.info("event id=%s bucket=%s name=%s", ce_id, bucket, name)
    try:
        result = ingest_pdf(bucket, name)
    except Exception as e:
        # Re-raise as 500 so Eventarc retries with backoff. Keep the message
        # short — the full traceback is already in Cloud Logging.
        log.exception("ingest failed bucket=%s name=%s", bucket, name)
        raise HTTPException(status_code=500, detail=f"ingest failed: {e}") from e

    return {
        "ok": True,
        "document_id": result.document_id,
        "gcs_uri": result.gcs_uri,
        "num_pages": result.num_pages,
        "num_chunks": result.num_chunks,
        "duration_ms": result.duration_ms,
    }
