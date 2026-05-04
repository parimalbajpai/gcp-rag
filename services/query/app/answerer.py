"""Top-level orchestration: question -> embedding -> retrieval -> answer."""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass

from .embedder import embed_query
from .llm import generate_answer
from .retriever import RetrievedChunk, retrieve

log = logging.getLogger(__name__)


@dataclass
class Citation:
    n: int                    # 1-indexed reference shown in the answer
    chunk_id: str
    document_id: str
    filename: str
    gcs_uri: str
    page_number: int | None
    rrf_score: float
    vector_rank: int | None
    keyword_rank: int | None


@dataclass
class AnswerResult:
    answer: str
    citations: list[Citation]
    duration_ms: int
    embed_ms: int
    retrieve_ms: int
    llm_ms: int


def _to_citations(chunks: list[RetrievedChunk]) -> list[Citation]:
    return [
        Citation(
            n=i,
            chunk_id=c.chunk_id,
            document_id=c.document_id,
            filename=c.filename,
            gcs_uri=c.gcs_uri,
            page_number=c.page_number,
            rrf_score=c.rrf_score,
            vector_rank=c.vector_rank,
            keyword_rank=c.keyword_rank,
        )
        for i, c in enumerate(chunks, start=1)
    ]


def answer_question(question: str) -> AnswerResult:
    overall = time.monotonic()

    t0 = time.monotonic()
    qvec = embed_query(question)
    embed_ms = int((time.monotonic() - t0) * 1000)

    t1 = time.monotonic()
    chunks = retrieve(question, qvec)
    retrieve_ms = int((time.monotonic() - t1) * 1000)

    t2 = time.monotonic()
    answer = generate_answer(question, chunks)
    llm_ms = int((time.monotonic() - t2) * 1000)

    duration_ms = int((time.monotonic() - overall) * 1000)
    log.info(
        "answered question chars=%d retrieved=%d embed_ms=%d retrieve_ms=%d llm_ms=%d total_ms=%d",
        len(question), len(chunks), embed_ms, retrieve_ms, llm_ms, duration_ms,
    )
    return AnswerResult(
        answer=answer,
        citations=_to_citations(chunks),
        duration_ms=duration_ms,
        embed_ms=embed_ms,
        retrieve_ms=retrieve_ms,
        llm_ms=llm_ms,
    )
