"""Vertex AI text embeddings.

We use `text-embedding-005` with task_type=RETRIEVAL_DOCUMENT for ingestion.
Query-time embedding (in the query service) MUST use task_type=RETRIEVAL_QUERY
against the same model — they're tuned to live in the same space, so mixing
task types degrades recall.

Vertex AI caps each call at 250 inputs; we batch with a configurable size
(default 100) for safety + smaller retries on transient errors.
"""
from __future__ import annotations

import logging
import time
from typing import Iterable

import vertexai
from vertexai.language_models import TextEmbeddingInput, TextEmbeddingModel

from .settings import get_settings

log = logging.getLogger(__name__)

_model: TextEmbeddingModel | None = None


def _get_model() -> TextEmbeddingModel:
    global _model
    if _model is None:
        s = get_settings()
        vertexai.init(project=s.gcp_project_id, location=s.vertex_ai_region)
        _model = TextEmbeddingModel.from_pretrained(s.embedding_model)
    return _model


def _batched(seq: list[str], n: int) -> Iterable[list[str]]:
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def embed_documents(texts: list[str]) -> list[list[float]]:
    """Embed N texts and return N vectors of length EMBEDDING_DIM.

    Order is preserved: result[i] corresponds to texts[i].
    """
    if not texts:
        return []

    s = get_settings()
    model = _get_model()
    out: list[list[float]] = []

    for batch in _batched(texts, s.embedding_batch_size):
        inputs = [TextEmbeddingInput(text=t, task_type="RETRIEVAL_DOCUMENT") for t in batch]
        # Simple retry: Vertex occasionally returns 429/503 under load.
        attempts = 0
        while True:
            try:
                resp = model.get_embeddings(inputs, output_dimensionality=s.embedding_dim)
                break
            except Exception as e:  # noqa: BLE001
                attempts += 1
                if attempts >= 4:
                    raise
                wait = 2 ** attempts
                log.warning("embed batch failed (attempt %d): %s; retrying in %ds", attempts, e, wait)
                time.sleep(wait)

        for emb in resp:
            vec = list(emb.values)
            if len(vec) != s.embedding_dim:
                raise RuntimeError(
                    f"Embedding dim mismatch: got {len(vec)}, expected {s.embedding_dim}"
                )
            out.append(vec)

    return out
