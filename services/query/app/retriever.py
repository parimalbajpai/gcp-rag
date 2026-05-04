"""Hybrid retrieval over the chunks table.

Two retrievers run independently and we fuse their ranked lists with
Reciprocal Rank Fusion (RRF):

    score(d) = sum over retrievers r:  1 / (k + rank_r(d))

  - Vector retriever: HNSW + cosine distance over `chunks.embedding`. Uses
    pgvector's `<=>` operator. The HNSW index from script 05 makes this fast.
  - Keyword retriever: PostgreSQL full-text search via the GIN index on
    `to_tsvector('english', content)`. Uses `websearch_to_tsquery` so the
    user can write Google-style queries with quotes / OR / -negation.

Why hybrid: vector search is great for semantic recall but can miss exact
identifiers (names, IDs, codes); keyword search nails those but misses
paraphrases. Fusing the two with RRF is a strong, simple default that
needs no per-query tuning.

Per-query knob: `SET LOCAL hnsw.ef_search = N` controls HNSW recall vs
latency. We set it once at the start of the transaction.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass

from pgvector.psycopg import register_vector

from . import db
from .settings import get_settings

log = logging.getLogger(__name__)


@dataclass
class RetrievedChunk:
    chunk_id: str
    document_id: str
    filename: str
    gcs_uri: str
    page_number: int | None
    content: str
    rrf_score: float
    vector_rank: int | None
    keyword_rank: int | None


# A single CTE-based query computes both rankings and fuses them in SQL.
# Doing the fusion in SQL keeps the round trip count to one and lets
# Postgres prune/rank without us shipping rows back and forth.
_HYBRID_SQL = """
WITH
-- top-N by ANN cosine distance
v AS (
  SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <=> %(qvec)s::vector) AS rnk
  FROM chunks
  ORDER BY embedding <=> %(qvec)s::vector
  LIMIT %(top_k)s
),
-- top-N by full-text rank, only over chunks that match the tsquery
k AS (
  SELECT id,
         ROW_NUMBER() OVER (
           ORDER BY ts_rank_cd(
             to_tsvector('english', content),
             websearch_to_tsquery('english', %(qtxt)s)
           ) DESC
         ) AS rnk
  FROM chunks
  WHERE to_tsvector('english', content) @@ websearch_to_tsquery('english', %(qtxt)s)
  ORDER BY ts_rank_cd(
             to_tsvector('english', content),
             websearch_to_tsquery('english', %(qtxt)s)
           ) DESC
  LIMIT %(top_k)s
)
SELECT
  c.id::text                                                          AS chunk_id,
  c.document_id::text                                                 AS document_id,
  d.filename                                                          AS filename,
  d.gcs_uri                                                           AS gcs_uri,
  c.page_number                                                       AS page_number,
  c.content                                                           AS content,
  COALESCE(1.0 / (%(rrf_k)s + v.rnk), 0)
    + COALESCE(1.0 / (%(rrf_k)s + k.rnk), 0)                          AS rrf_score,
  v.rnk                                                               AS vector_rank,
  k.rnk                                                               AS keyword_rank
FROM chunks c
JOIN documents d ON d.id = c.document_id
LEFT JOIN v ON v.id = c.id
LEFT JOIN k ON k.id = c.id
WHERE (v.id IS NOT NULL OR k.id IS NOT NULL)
  AND d.status = 'completed'
ORDER BY rrf_score DESC
LIMIT %(final_k)s;
"""


def retrieve(query_text: str, query_embedding: list[float]) -> list[RetrievedChunk]:
    s = get_settings()
    params = {
        "qvec": query_embedding,
        "qtxt": query_text,
        "top_k": s.retrieve_top_k,
        "rrf_k": s.rrf_k,
        "final_k": s.final_top_k,
    }

    # SET LOCAL is a utility command and can't take bind parameters, so we
    # interpolate the int directly. ef_search comes from settings (not user
    # input) and is forced to int so this is injection-safe.
    ef = int(s.hnsw_ef_search)
    set_ef_sql = f"SET LOCAL hnsw.ef_search = {ef}"

    with db.connect() as conn:
        register_vector(conn)
        with conn.cursor() as cur:
            # Recall knob for HNSW; transaction-local so it doesn't leak.
            cur.execute(set_ef_sql)
            cur.execute(_HYBRID_SQL, params)
            rows = cur.fetchall()

    out: list[RetrievedChunk] = []
    for r in rows:
        out.append(RetrievedChunk(
            chunk_id=r[0],
            document_id=r[1],
            filename=r[2],
            gcs_uri=r[3],
            page_number=r[4],
            content=r[5],
            rrf_score=float(r[6]),
            vector_rank=r[7],
            keyword_rank=r[8],
        ))
    return out
