"""Recursive character chunker.

We chunk per-page so we can preserve `page_number` metadata on each chunk.
That metadata is what lets the chat UI later render "source: page 7" citations.

The recursive splitter tries a hierarchy of separators (paragraph, line,
sentence, space, char) so chunks usually break on natural boundaries
instead of mid-word.
"""
from __future__ import annotations

from dataclasses import dataclass

from langchain_text_splitters import RecursiveCharacterTextSplitter

from .extractor import Page
from .settings import get_settings


@dataclass
class Chunk:
    chunk_index: int   # 0-indexed, document-wide order
    page_number: int   # the page this chunk came from
    content: str


def _splitter() -> RecursiveCharacterTextSplitter:
    s = get_settings()
    return RecursiveCharacterTextSplitter(
        chunk_size=s.chunk_size_chars,
        chunk_overlap=s.chunk_overlap_chars,
        # Order matters: try big breaks first, fall back to finer ones.
        separators=["\n\n", "\n", ". ", " ", ""],
        length_function=len,
        is_separator_regex=False,
    )


def chunk_pages(pages: list[Page]) -> list[Chunk]:
    """Split each page into chunks and assign a document-wide chunk_index."""
    splitter = _splitter()
    out: list[Chunk] = []
    idx = 0
    for page in pages:
        for piece in splitter.split_text(page.text):
            piece = piece.strip()
            if not piece:
                continue
            out.append(Chunk(chunk_index=idx, page_number=page.page_number, content=piece))
            idx += 1
    return out
