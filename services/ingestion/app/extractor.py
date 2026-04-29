"""PDF text extraction using pypdf.

For born-digital PDFs (most invoices, exports, reports), pypdf gives clean
results. For scanned/image-only PDFs, the extracted text will be empty or
near-empty, and you'll want to swap in Document AI's OCR/Layout Parser.
"""
from __future__ import annotations

from dataclasses import dataclass
from io import BytesIO

from pypdf import PdfReader


@dataclass
class Page:
    page_number: int  # 1-indexed
    text: str


def extract_pages(pdf_bytes: bytes) -> list[Page]:
    """Return one Page per PDF page, in order. Strips fully-empty pages."""
    reader = PdfReader(BytesIO(pdf_bytes))
    pages: list[Page] = []
    for i, p in enumerate(reader.pages, start=1):
        try:
            text = p.extract_text() or ""
        except Exception:
            # pypdf can raise on malformed page resources; skip rather than
            # fail the whole document.
            text = ""
        text = text.strip()
        if text:
            pages.append(Page(page_number=i, text=text))
    return pages


def num_pages(pdf_bytes: bytes) -> int:
    return len(PdfReader(BytesIO(pdf_bytes)).pages)
