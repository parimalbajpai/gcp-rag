"""Database layer (psycopg 3 + pgvector).

Schema reference (from scripts/05-create-schema.sh):

  documents(
    id, gcs_uri UNIQUE, filename, content_hash, size_bytes, num_pages,
    status CHECK IN ('pending','processing','completed','failed'),
    error, metadata jsonb, uploaded_at, processed_at
  )
  chunks(
    id, document_id FK, chunk_index, page_number, content, token_count,
    embedding vector(N), metadata jsonb, created_at,
    UNIQUE(document_id, chunk_index)
  )
  ingestion_events(
    id bigserial, document_id, gcs_uri NOT NULL, event_type, message,
    payload jsonb, created_at
  )

Idempotency:
- documents.gcs_uri is UNIQUE -> upsert by gcs_uri.
- chunks (document_id, chunk_index) is UNIQUE; we DELETE+INSERT on reingest.
"""
from __future__ import annotations

import logging
from contextlib import contextmanager
from typing import Iterator

import psycopg
from pgvector.psycopg import register_vector
from psycopg.types.json import Json

from .chunker import Chunk
from .settings import get_settings

log = logging.getLogger(__name__)


@contextmanager
def connect() -> Iterator[psycopg.Connection]:
    s = get_settings()
    conn = psycopg.connect(s.db_conninfo)
    try:
        register_vector(conn)
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def upsert_document(
    *,
    gcs_uri: str,
    filename: str,
    content_hash: str,
    num_pages: int,
    metadata: dict | None = None,
) -> str:
    """Insert or update a document row; return its UUID as a string.

    Marks status='processing' so the row reflects an in-flight ingest. The
    pipeline transitions it to 'completed' (or 'failed') at the end.
    """
    md = metadata or {}
    sql = """
        INSERT INTO documents (gcs_uri, filename, content_hash, num_pages, status, metadata)
        VALUES (%s, %s, %s, %s, 'processing', %s)
        ON CONFLICT (gcs_uri) DO UPDATE
          SET filename     = EXCLUDED.filename,
              content_hash = EXCLUDED.content_hash,
              num_pages    = EXCLUDED.num_pages,
              status       = 'processing',
              error        = NULL,
              metadata     = EXCLUDED.metadata,
              processed_at = NULL
        RETURNING id::text
    """
    with connect() as conn, conn.cursor() as cur:
        cur.execute(sql, (gcs_uri, filename, content_hash, num_pages, Json(md)))
        row = cur.fetchone()
        if not row:
            raise RuntimeError("documents upsert returned no row")
        return row[0]


def replace_chunks(document_id: str, chunks: list[Chunk], embeddings: list[list[float]]) -> int:
    """Replace all chunks for a document and write new embeddings.

    Strategy: DELETE then bulk INSERT inside one transaction. Simpler and
    faster than per-row UPSERT for a few thousand rows, and ensures stale
    chunks from a prior version don't linger.
    """
    if len(chunks) != len(embeddings):
        raise ValueError(f"chunks/embeddings length mismatch: {len(chunks)} vs {len(embeddings)}")

    with connect() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM chunks WHERE document_id = %s", (document_id,))
        if not chunks:
            return 0

        rows = [
            (document_id, c.chunk_index, c.page_number, c.content, len(c.content), emb)
            for c, emb in zip(chunks, embeddings)
        ]
        cur.executemany(
            """
            INSERT INTO chunks
              (document_id, chunk_index, page_number, content, token_count, embedding)
            VALUES (%s, %s, %s, %s, %s, %s)
            """,
            rows,
        )
        return len(rows)


def mark_completed(document_id: str) -> None:
    """Transition documents.status -> 'completed' and stamp processed_at."""
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE documents
               SET status       = 'completed',
                   error        = NULL,
                   processed_at = NOW()
             WHERE id = %s
            """,
            (document_id,),
        )


def mark_failed(document_id: str, error: str) -> None:
    """Transition documents.status -> 'failed' and store the error message."""
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE documents
               SET status       = 'failed',
                   error        = %s,
                   processed_at = NOW()
             WHERE id = %s
            """,
            (error, document_id),
        )


def record_event(
    *,
    document_id: str | None,
    gcs_uri: str,
    event_type: str,
    message: str | None = None,
    payload: dict | None = None,
) -> None:
    """Append a row to ingestion_events for audit/debug.

    Best-effort: failures here are logged but never re-raised, so a logging
    glitch doesn't kill an otherwise-successful ingest.
    """
    pl = payload or {}
    try:
        with connect() as conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO ingestion_events
                  (document_id, gcs_uri, event_type, message, payload)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (document_id, gcs_uri, event_type, message, Json(pl)),
            )
    except Exception as e:  # noqa: BLE001
        log.warning("record_event failed (%s): %s", event_type, e)
