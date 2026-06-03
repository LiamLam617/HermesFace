# HermesFace on Hugging Face Spaces — Source build
# Builds Hermes Agent from source since no pre-built Docker image is published
# Rebuild 2026-04-13: initial release

# ── Stage 1: Build 9Router ────────────────────────────────────────────────
FROM node:22-alpine AS ninerouter_builder
WORKDIR /app
RUN apk --no-cache add git python3 make g++ linux-headers
RUN apk --no-cache upgrade && apk --no-cache add git python3 make g++ linux-headers
RUN git clone --depth 1 https://github.com/decolua/9router.git /app
RUN npm install
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# ── Stage 2: Build Hermes Agent from source ───────────────────────────────
FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie AS uv_source
FROM tianon/gosu:1.19-trixie AS gosu_source

FROM debian:13.4
SHELL ["/bin/bash", "-c"]
ENV PYTHONUNBUFFERED=1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# ── System dependencies ───────────────────────────────────────────────────
RUN echo "[build] Installing system deps..." && START=$(date +%s) \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential nodejs npm python3 python3-pip python3-venv \
        ripgrep ffmpeg gcc python3-dev libffi-dev procps \
        git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir --break-system-packages huggingface_hub requests pyyaml \
    && echo "[build] System deps: $(($(date +%s) - START))s"

# ── 複製 9Router 建置產物 ───────────────────────────────────────────────
COPY --from=ninerouter_builder /app/public         /opt/9router/public
COPY --from=ninerouter_builder /app/.next/static   /opt/9router/.next/static
COPY --from=ninerouter_builder /app/.next/standalone /opt/9router/
COPY --from=ninerouter_builder /app/open-sse       /opt/9router/open-sse
COPY --from=ninerouter_builder /app/src/mitm       /opt/9router/src/mitm
COPY --from=ninerouter_builder /app/node_modules/node-forge /opt/9router/node_modules/node-forge
COPY --from=ninerouter_builder /app/node_modules/next /opt/9router/node_modules/next

# ── Non-root user ────────────────────────────────────────────────────────
RUN useradd -u 10000 -m -d /opt/data hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

# ── Clone and build Hermes Agent ─────────────────────────────────────────
RUN echo "[build] Cloning Hermes Agent..." && START=$(date +%s) \
  && git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /opt/hermes \
  && echo "[build] Clone: $(($(date +%s) - START))s"

WORKDIR /opt/hermes

# ── Node dependencies + Playwright + Web Dashboard build ─────────────────
RUN echo "[build] Installing Node deps + Playwright..." && START=$(date +%s) \
  && npm install --prefer-offline --no-audit \
  && npx playwright install --with-deps chromium --only-shell \
  && if [ -d /opt/hermes/scripts/whatsapp-bridge ]; then \
       cd /opt/hermes/scripts/whatsapp-bridge && npm install --prefer-offline --no-audit; \
     fi \
  && echo "[build] Building web dashboard..." \
  && cd /opt/hermes/web && npm install --prefer-offline --no-audit && npm run build \
  && cd /opt/hermes && npm cache clean --force \
  && echo "[build] Node deps + web dashboard: $(($(date +%s) - START))s"

# ── Python dependencies ──────────────────────────────────────────────────
RUN chown -R hermes:hermes /opt/hermes
USER hermes

RUN echo "[build] Installing Python deps..." && START=$(date +%s) \
  && cd /opt/hermes \
  && uv venv \
  && uv pip install --no-cache-dir -e ".[all]" \
  && echo "[build] Python deps: $(($(date +%s) - START))s"

USER root
RUN chmod +x /opt/hermes/docker/entrypoint.sh

# ── Prepare runtime dirs ────────────────────────────────────────────────
RUN mkdir -p /opt/data/cron /opt/data/sessions /opt/data/logs /opt/data/hooks \
             /opt/data/memories /opt/data/skills /opt/data/skins /opt/data/plans \
             /opt/data/workspace /opt/data/home \
  && chown -R hermes:hermes /opt/data

USER hermes

# ── HermesFace scripts (persistence + entrypoint + DNS + assets) ──────
ARG CACHE_BUST=2026-04-22-v2
RUN echo "Build: ${CACHE_BUST}"
COPY --chown=hermes:hermes scripts /opt/hermes-scripts/scripts
COPY --chown=hermes:hermes assets  /opt/hermes-scripts/assets

RUN find /opt/hermes-scripts/scripts -type f \( -name "*.sh" -o -name "*.py" \) \
    -exec sed -i 's/\r$//' {} \;
    
RUN chmod +x /opt/hermes-scripts/scripts/entrypoint.sh \
    /opt/hermes-scripts/scripts/dns-resolve.py \
    /opt/hermes-scripts/scripts/hermes_persist.py \
    /opt/hermes-scripts/scripts/save_to_dataset.py \
    /opt/hermes-scripts/scripts/save_to_dataset_atomic.py \
    /opt/hermes-scripts/scripts/restore_from_dataset.py \
    /opt/hermes-scripts/scripts/restore_from_dataset_atomic.py \
    /opt/hermes-scripts/scripts/sync_hf.py

ENV HERMES_HOME=/opt/data
ENV PATH="/opt/hermes/.venv/bin:$PATH"
WORKDIR /opt/data
USER root
CMD ["/opt/hermes-scripts/scripts/entrypoint.sh"]
