FROM python:3.11-slim AS builder

WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc default-libmysqlclient-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# --------------------------------------------------------------------------------------------------------------------------------------------------------

FROM python:3.11-slim AS runtime

RUN groupadd -r hybe && useradd -r -g hybe -s /sbin/nologin hybeapp

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    default-libmysqlclient-dev curl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /install /usr/local
COPY app.py .

ENV POD_NAME="merch-pod-unknown"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV CART_TTL_SECONDS=300

CMD ["gunicorn", \
      "--workers", "4", \
      "--threads", "4", \
      "--bind", "0.0.0.0:8081", \
      "--timeout", "60", \
      "--keep-alive", "5", \
      "--access-logfile", "-", \
      "--error-logfile", "-", \
      "app:app"]

USER hybeapp
EXPOSE 8081

HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:8081/health/live || exit 1

LABEL maintainer="devops@hybe.com" \
      service="merch-service" \
      version="1.0.0"