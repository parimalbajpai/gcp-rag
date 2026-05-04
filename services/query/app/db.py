"""Read-only DB access for the query service.

Only one entry point: `connect()`. Caller is responsible for registering
pgvector on the connection if it needs to bind vector params.
"""
from __future__ import annotations

from contextlib import contextmanager
from typing import Iterator

import psycopg

from .settings import get_settings


@contextmanager
def connect() -> Iterator[psycopg.Connection]:
    s = get_settings()
    conn = psycopg.connect(s.db_conninfo)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
