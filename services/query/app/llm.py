"""Gemini call for grounded answer generation.

We pass retrieved chunks as numbered "[N] filename p.X" snippets and ask
the model to cite them inline as [1], [2], ... — this is the simplest
citation scheme that survives the model rephrasing things.

System prompt is intentionally conservative: don't invent facts, say "I
don't know" when the context doesn't cover the question. This is the
single biggest dial for hallucination on small RAG setups.
"""
from __future__ import annotations

import logging

import vertexai
from vertexai.generative_models import GenerationConfig, GenerativeModel

from .retriever import RetrievedChunk
from .settings import get_settings

log = logging.getLogger(__name__)

_model: GenerativeModel | None = None


SYSTEM_PROMPT = """\
You are an assistant that answers questions strictly from the provided document context.

Rules:
- Only use facts present in the CONTEXT. If the answer is not supported by the context, say:
  "I don't have enough information in the documents to answer that."
- Cite sources inline using bracketed numbers like [1], [2] that match the context items.
- Multiple citations are fine: [1][3].
- Be concise. Prefer short, direct answers over long ones.
- Do not invent filenames, page numbers, or quotes."""


def _get_model() -> GenerativeModel:
    global _model
    if _model is None:
        s = get_settings()
        vertexai.init(project=s.gcp_project_id, location=s.vertex_ai_region)
        _model = GenerativeModel(s.llm_model, system_instruction=[SYSTEM_PROMPT])
    return _model


def _format_context(chunks: list[RetrievedChunk]) -> str:
    lines: list[str] = []
    for i, c in enumerate(chunks, start=1):
        page = f"p.{c.page_number}" if c.page_number is not None else "p.?"
        header = f"[{i}] {c.filename} ({page})"
        lines.append(f"{header}\n{c.content.strip()}")
    return "\n\n---\n\n".join(lines)


def generate_answer(question: str, chunks: list[RetrievedChunk]) -> str:
    if not chunks:
        return "I don't have enough information in the documents to answer that."

    context = _format_context(chunks)
    prompt = (
        f"CONTEXT:\n{context}\n\n"
        f"QUESTION: {question}\n\n"
        f"Answer using only the context above, and cite sources inline as [1], [2], etc."
    )

    model = _get_model()
    resp = model.generate_content(
        prompt,
        generation_config=GenerationConfig(
            temperature=0.2,        # low: we want grounded, not creative
            max_output_tokens=1024,
            top_p=0.95,
        ),
    )
    # Vertex's response.text raises if there were safety blocks; fall back gracefully.
    try:
        return resp.text or ""
    except Exception:  # noqa: BLE001
        log.warning("Gemini response had no usable text; candidates=%s", resp.candidates)
        return "I couldn't generate an answer for that question."
