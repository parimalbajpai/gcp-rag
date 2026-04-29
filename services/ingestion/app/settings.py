"""Runtime configuration. All values come from environment variables.

Cloud Run sets these via `--set-env-vars` and `--set-secrets` (see
scripts/06-deploy-ingestion.sh). For local dev, copy .env.example to .env.
"""
from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # GCP project + regions
    gcp_project_id: str = Field(..., alias="GCP_PROJECT_ID")
    gcp_region: str = Field(..., alias="GCP_REGION")
    vertex_ai_region: str = Field("us-central1", alias="VERTEX_AI_REGION")

    # Database (Cloud SQL Postgres). On Cloud Run, db_host is the unix socket
    # path /cloudsql/<connection-name>. Locally, override to 127.0.0.1.
    db_host: str = Field(..., alias="DB_HOST")
    db_port: int = Field(5432, alias="DB_PORT")
    db_name: str = Field(..., alias="DB_NAME")
    db_user: str = Field(..., alias="DB_USER")
    db_password: str = Field(..., alias="DB_PASSWORD")

    # Embeddings
    embedding_model: str = Field("text-embedding-005", alias="EMBEDDING_MODEL")
    embedding_dim: int = Field(768, alias="EMBEDDING_DIM")
    # Max texts per Vertex AI embedding call. text-embedding-* limit is 250.
    embedding_batch_size: int = Field(100, alias="EMBEDDING_BATCH_SIZE")

    # Chunking
    chunk_size_chars: int = Field(2000, alias="CHUNK_SIZE_CHARS")
    chunk_overlap_chars: int = Field(300, alias="CHUNK_OVERLAP_CHARS")

    # Storage
    processed_bucket: str = Field(..., alias="PROCESSED_BUCKET")

    @property
    def db_conninfo(self) -> str:
        # psycopg connection string.
        return (
            f"host={self.db_host} "
            f"port={self.db_port} "
            f"dbname={self.db_name} "
            f"user={self.db_user} "
            f"password={self.db_password}"
        )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
