# ---- web build
FROM node:22-alpine AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
RUN npx vite build

# ---- runtime
FROM python:3.12-slim
ARG WITH_STEP=true
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    VAULT_LIBRARY=/library VAULT_DATA=/data VAULT_INBOX=/inbox VAULT_WEB=/app/web
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libxrender1 libxext6 libxi6 libxcursor1 libxft2 libxinerama1 curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY server/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
    && if [ "$WITH_STEP" = "true" ]; then pip install --no-cache-dir cadquery-ocp==8.0.1.1.0; fi
COPY server/app ./app
COPY --from=web /web/dist ./web
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /library /data /inbox
EXPOSE 8000
VOLUME ["/library", "/data", "/inbox"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD curl -fs http://localhost:8000/api/health || exit 1
ENTRYPOINT ["/entrypoint.sh"]
