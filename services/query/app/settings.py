"""Runtime configuration. All values come from environment variables.

Cloud Run sets these via `--set-env-vars` and `--set-secrets` (see
scripts/08-deploy-query.sh). For local dev, copy .env.example to .env.
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

    # Database
    db_host: str = Field(..., alias="DB_HOST")
    db_port: int = Field(5432, alias="DB_PORT")
    db_name: str = Field(..., alias="DB_NAME")
    db_user: str = Field(..., alias="DB_USER")
    db_password: str = Field(..., alias="DB_PASSWORD")

    # Embeddings (must match what ingestion used)
    embedding_model: str = Field("text-embedding-005", alias="EMBEDDING_MODEL")
    embedding_dim: int = Field(768, alias="EMBEDDING_DIM")

    # Generation
    llm_model: str = Field("gemini-2.0-flash-001", alias="LLM_MODEL")

    # Retrieval tuning
    retrieve_top_k: int = Field(20, alias="RETRIEVE_TOP_K")
    final_top_k: int = Field(8, alias="FINAL_TOP_K")
    rrf_k: int = Field(60, alias="RRF_K")
    hnsw_ef_search: int = Field(80, alias="HNSW_EF_SEARCH")

    @property
    def db_conninfo(self) -> str:
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
