"""Google Cloud Storage helpers."""
from __future__ import annotations

from google.cloud import storage

_client: storage.Client | None = None


def _get_client() -> storage.Client:
    global _client
    if _client is None:
        _client = storage.Client()
    return _client


def parse_gs_uri(uri: str) -> tuple[str, str]:
    """Split 'gs://bucket/some/object/path' into (bucket, object_name)."""
    if not uri.startswith("gs://"):
        raise ValueError(f"Not a gs:// URI: {uri!r}")
    rest = uri[len("gs://"):]
    if "/" not in rest:
        raise ValueError(f"Missing object name in URI: {uri!r}")
    bucket, name = rest.split("/", 1)
    return bucket, name


def gs_uri(bucket: str, name: str) -> str:
    return f"gs://{bucket}/{name}"


def download_bytes(bucket: str, name: str) -> bytes:
    """Download an object's raw bytes from GCS."""
    blob = _get_client().bucket(bucket).blob(name)
    return blob.download_as_bytes()


def upload_text(bucket: str, name: str, text: str, content_type: str = "text/plain") -> str:
    """Upload UTF-8 text and return the gs:// URI."""
    blob = _get_client().bucket(bucket).blob(name)
    blob.upload_from_string(text, content_type=content_type)
    return gs_uri(bucket, name)
