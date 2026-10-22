# Build args used in FROM lines must be declared before the first stage.
ARG WITH_SLICER=true

# ---- web build
FROM node:22-alpine AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
RUN npx vite build

# ---- OrcaSlicer for server-side slicing (x86_64 only). The AppImage's squashfs starts right after
# its ELF runtime (section header offset + size), so it is unpacked directly and runs without FUSE.
FROM debian:trixie-slim AS orca
ARG ORCA_VERSION=2.4.2
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl squashfs-tools && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/orca.AppImage \
      "https://github.com/SoftFever/OrcaSlicer/releases/download/v${ORCA_VERSION}/OrcaSlicer_Linux_AppImage_Ubuntu2404_V${ORCA_VERSION}.AppImage" \
    && f=/tmp/orca.AppImage \
    && shoff=$(od -An -t u8 -j 40 -N 8 $f | tr -d ' ') \
    && shentsize=$(od -An -t u2 -j 58 -N 2 $f | tr -d ' ') \
    && shnum=$(od -An -t u2 -j 60 -N 2 $f | tr -d ' ') \
    && unsquashfs -q -o $((shoff + shentsize * shnum)) -d /opt/orca $f \
    && rm $f

# WITH_SLICER picks one of these two stages, so a build without the slicer copies nothing.
FROM orca AS orca-true
FROM debian:trixie-slim AS orca-false
RUN mkdir -p /opt/orca
FROM orca-${WITH_SLICER} AS orca-selected

# ---- runtime
FROM python:3.12-slim-trixie
ARG WITH_STEP=true
ARG WITH_SLICER=true
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
# Libraries OrcaSlicer links against. It runs headless on the command line, but still loads GTK.
RUN if [ "$WITH_SLICER" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        libgtk-3-0t64 libwebkit2gtk-4.1-0 libegl1 libgl1 libglu1-mesa libosmesa6 libgstreamer1.0-0 \
        libgstreamer-plugins-base1.0-0 libsecret-1-0 libsoup-3.0-0 libsm6 libice6 libmspack0t64 \
      && rm -rf /var/lib/apt/lists/*; fi
COPY --from=orca-selected /opt/orca /opt/orca
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /library /data /inbox
EXPOSE 8000
VOLUME ["/library", "/data", "/inbox"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD curl -fs http://localhost:8000/api/health || exit 1
ENTRYPOINT ["/entrypoint.sh"]
