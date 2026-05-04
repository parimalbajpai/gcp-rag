"""Vertex AI text embeddings — query side.

Critical: query embeddings MUST use task_type=RETRIEVAL_QUERY against the
SAME model as ingestion (text-embedding-005). Document and query embeddings
are tuned to live in the same space, so mismatched task_type silently
degrades recall.
"""
from __future__ import annotations

import logging

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


def embed_query(text: str) -> list[float]:
    """Embed a single user question and return a vector of length EMBEDDING_DIM."""
    if not text.strip():
        raise ValueError("empty query")

    s = get_settings()
    model = _get_model()
    [emb] = model.get_embeddings(
        [TextEmbeddingInput(text=text, task_type="RETRIEVAL_QUERY")],
        output_dimensionality=s.embedding_dim,
    )
    vec = list(emb.values)
    if len(vec) != s.embedding_dim:
        raise RuntimeError(
            f"Embedding dim mismatch: got {len(vec)}, expected {s.embedding_dim}"
        )
    return vec
