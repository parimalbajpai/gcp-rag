"""FastAPI HTTP entry point for the query service.

Routes:
  GET  /healthz            - Cloud Run readiness check
  POST /query              - { "question": "..." } -> { answer, citations, timing }

This service is deployed --no-allow-unauthenticated. Callers (the chat
frontend, or `curl` during testing) need to attach an OIDC ID token.
"""
from __future__ import annotations

import logging
import os
from dataclasses import asdict

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from .answerer import answer_question

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("query")

app = FastAPI(title="pdf-rag-query", version="0.1.0")


class QueryRequest(BaseModel):
    question: str = Field(..., min_length=1, max_length=4000)


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True}


@app.post("/query")
def query(req: QueryRequest) -> dict:
    try:
        result = answer_question(req.question)
    except Exception as e:
        log.exception("query failed")
        raise HTTPException(status_code=500, detail=f"query failed: {e}") from e

    return {
        "answer": result.answer,
        "citations": [asdict(c) for c in result.citations],
        "timing": {
            "embed_ms": result.embed_ms,
            "retrieve_ms": result.retrieve_ms,
            "llm_ms": result.llm_ms,
            "total_ms": result.duration_ms,
        },
    }
