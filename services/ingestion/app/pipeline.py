"""End-to-end ingestion pipeline.

Steps for a single PDF at gs://bucket/path.pdf:

  1. Download bytes from GCS.
  2. Hash the bytes (sha256). Used as content_hash in documents.
  3. Extract text per page (pypdf).
  4. Chunk per page with a recursive character splitter.
  5. Persist the extracted plain text alongside the PDF in the processed bucket
     for debugging / re-runs.
  6. Embed all chunks with Vertex AI text-embedding-005.
  7. Upsert document + replace chunks in Postgres.
  8. Mark document 'completed'.

If anything fails after we've created the documents row, we mark it 'failed'
and re-raise so the Cloud Run request returns 5xx (Eventarc will retry).
"""
from __future__ import annotations

import hashlib
import logging
import os
import time
from dataclasses import dataclass

from . import db, gcs
from .chunker import chunk_pages
from .embedder import embed_documents
from .extractor import extract_pages, num_pages
from .settings import get_settings

log = logging.getLogger(__name__)


@dataclass
class IngestResult:
    document_id: str
    gcs_uri: str
    num_pages: int
    num_chunks: int
    duration_ms: int
    skipped: bool = False
    reason: str = ""


def _processed_text_name(raw_name: str) -> str:
    """Mirror the raw object's path under the processed bucket as .txt."""
    base, _ = os.path.splitext(raw_name)
    return f"{base}.txt"


def ingest_pdf(raw_bucket: str, raw_name: str) -> IngestResult:
    s = get_settings()
    started = time.monotonic()
    uri = gcs.gs_uri(raw_bucket, raw_name)
    log.info("ingest start uri=%s", uri)

    # 1. Download
    pdf_bytes = gcs.download_bytes(raw_bucket, raw_name)
    if not pdf_bytes:
        raise ValueError(f"empty object: {uri}")

    # 2. Hash
    content_hash = hashlib.sha256(pdf_bytes).hexdigest()
    total_pages = num_pages(pdf_bytes)

    # 3. Create / refresh the document row (status=processing)
    document_id = db.upsert_document(
        gcs_uri=uri,
        filename=os.path.basename(raw_name),
        content_hash=content_hash,
        num_pages=total_pages,
        metadata={"raw_bucket": raw_bucket, "raw_object": raw_name},
    )
    db.record_event(
        document_id=document_id,
        gcs_uri=uri,
        event_type="started",
        payload={"bytes": len(pdf_bytes)},
    )

    try:
        # 4. Extract
        pages = extract_pages(pdf_bytes)
        if not pages:
            # Born-digital extraction yielded nothing: likely a scanned PDF.
            # For v1 we mark as failed so the operator sees it; v2 will fall
            # back to Document AI OCR here.
            raise ValueError(
                "no extractable text (likely scanned PDF; needs Document AI OCR)"
            )

        # 5. Persist plain text for debugging
        joined = "\n\n".join(f"[page {p.page_number}]\n{p.text}" for p in pages)
        gcs.upload_text(
            s.processed_bucket,
            _processed_text_name(raw_name),
            joined,
            content_type="text/plain; charset=utf-8",
        )

        # 6. Chunk + embed
        chunks = chunk_pages(pages)
        if not chunks:
            raise ValueError("chunker produced 0 chunks from non-empty pages")
        embeddings = embed_documents([c.content for c in chunks])

        # 7. Replace chunks atomically
        n = db.replace_chunks(document_id, chunks, embeddings)

        # 8. Mark completed
        db.mark_completed(document_id)

        duration_ms = int((time.monotonic() - started) * 1000)
        db.record_event(
            document_id=document_id,
            gcs_uri=uri,
            event_type="completed",
            payload={"num_chunks": n, "duration_ms": duration_ms},
        )
        log.info(
            "ingest done uri=%s pages=%d chunks=%d duration_ms=%d",
            uri, len(pages), n, duration_ms,
        )
        return IngestResult(
            document_id=document_id,
            gcs_uri=uri,
            num_pages=len(pages),
            num_chunks=n,
            duration_ms=duration_ms,
        )

    except Exception as e:
        db.mark_failed(document_id, str(e))
        db.record_event(
            document_id=document_id,
            gcs_uri=uri,
            event_type="failed",
            message=str(e),
            payload={},
        )
        log.exception("ingest failed uri=%s", uri)
        raise
