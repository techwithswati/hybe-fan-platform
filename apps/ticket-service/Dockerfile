# ----- Stage 1: Builder ---------------------------------------------------------------------------------------------------------------------------------------------------------
FROM python:3.11-slim AS builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    default-libmysqlclient-dev \
    pkg-config \
  && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- Stage 2: Runtime ----------------------------------------------------------------------------------------------------------------------------------------------------------
FROM python:3.11-slim AS runtime

# Security: non-root user
RUN groupadd -r hybe && useradd -r -g hybe -s /sbin/nologin hybeapp

WORKDIR /app

# Runtime libs only
RUN apt-get update && apt-get install -y --no-install-recommends \
    default-libmysqlclient-dev \
    curl \
  && rm -rf /var/lib/apt/lists/*

# Copy installed packages from builder
COPY --from=builder /install /usr/local

COPY app.py .

# Pod name injected at runtime via Kubernetes downward API
ENV POD_NAME="ticket-pod-unknown"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Gunicorn: 4 workers x 4 threads = 16 concurrent requests per pod
CMD ["gunicorn", \
      "--workers", "4", \
      "--threads", "4", \
      "--bind", "0.0.0.0:8080", \
      "--timeout", "60", \
      "--keep-alive", "5", \
      "--access-logfile", "-", \
      "--error-logfile", "-", \
      "--log-level", "info", \
      "app:app"]

USER hybeapp
EXPOSE 8080

# Docker health check (Kubernetes probes override this)
HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:8080/health/live || exit 1

LABEL maintainer="devops@hybe.com" \
      service="ticket-service" \
      version="1.0.0"