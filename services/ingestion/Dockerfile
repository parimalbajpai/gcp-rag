# Slim Python base. Bullseye's libpq + libstdc++ are needed by psycopg[binary]
# and the GCP client libs.
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Install dependencies first for better layer caching.
COPY requirements.txt .
RUN pip install -r requirements.txt

# Copy application source.
COPY app ./app

# Cloud Run sets $PORT (default 8080). uvicorn reads it via env in CMD below.
ENV PORT=8080
EXPOSE 8080

# 1 worker is correct for Cloud Run (it scales horizontally via instances).
# Concurrency >1 is fine since FastAPI is async.
CMD exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --workers 1
