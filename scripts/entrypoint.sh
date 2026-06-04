#!/bin/bash
set -e

# ── 初始化 /opt/data 目錄權限（Storage Bucket mount 後為 root 擁有）──
# gosu 以 root 身份執行，確保目錄建立後轉交給 hermes user
if [ "$(id -u)" = "0" ]; then
    echo "[entrypoint] Running as root, fixing /opt/data permissions..."
    mkdir -p /opt/data/9router-data \
             /opt/data/scripts \
             /opt/data/cron \
             /opt/data/sessions \
             /opt/data/logs \
             /opt/data/hooks \
             /opt/data/memories \
             /opt/data/skills \
             /opt/data/skins \
             /opt/data/plans \
             /opt/data/workspace \
             /opt/data/home
    chown -R hermes:hermes /opt/data
    echo "[entrypoint] /opt/data permissions fixed"
    # 切換到 hermes user 繼續執行
    exec gosu hermes "$0" "$@"
fi

# ── 等待 Storage Bucket FUSE 掛載穩定 ──────────────────
echo "[entrypoint] Waiting for Storage Bucket to stabilize..."
for i in $(seq 1 10); do
    if touch /opt/data/.bucket_check 2>/dev/null; then
        rm -f /opt/data/.bucket_check
        echo "[entrypoint] Bucket ready after ${i}s"
        break
    fi
    sleep 1
done

# ── 啟動 9Router（背景進程）────────────────────────────────────────────
echo "[entrypoint] Starting 9Router on port 20128..."

export NINEROUTER_DATA_DIR="/opt/data/9router-data"
mkdir -p "$NINEROUTER_DATA_DIR"

PORT=20128 \
HOSTNAME=0.0.0.0 \
NODE_ENV=production \
NEXT_PUBLIC_BASE_URL=http://localhost:20128 \
DATA_DIR="$NINEROUTER_DATA_DIR" \
JWT_SECRET="${NINEROUTER_JWT_SECRET}" \
INITIAL_PASSWORD="${NINEROUTER_PASSWORD}" \
REQUIRE_API_KEY=true \
AUTH_COOKIE_SECURE=false \
node /opt/9router/server.js &

NINEROUTER_PID=$!
echo "[entrypoint] 9Router PID: $NINEROUTER_PID"

# 等待 9Router 就緒（最多 30 秒）
for i in $(seq 1 30); do
    if curl -sf http://localhost:20128/api/health > /dev/null 2>&1; then
        echo "[entrypoint] 9Router ready after ${i}s"
        break
    fi
    sleep 1
done

BOOT_START=$(date +%s)

echo "[entrypoint] HermesFace — Hermes Agent on HuggingFace Spaces"
echo "[entrypoint] ===================================================="

HERMES_HOME="/opt/data"
SCRIPTS_SRC="/opt/hermes-scripts/scripts"

# ── 把 scripts 複製到 HERMES_HOME（Bucket 已 mount，目錄存在）
echo "[entrypoint] Copying scripts to HERMES_HOME..."
mkdir -p "$HERMES_HOME/scripts"
cp -r "$SCRIPTS_SRC"/. "$HERMES_HOME/scripts/"
chmod +x "$HERMES_HOME/scripts/"*.sh "$HERMES_HOME/scripts/"*.py 2>/dev/null || true

INSTALL_DIR="/opt/hermes"
# ── DNS pre-resolution (background — non-blocking) ────────────────────────
# Resolves Telegram / WhatsApp / Discord domains via DoH when HF Spaces
# system DNS refuses them. Writes /tmp/dns-resolved.json for dns-fix.cjs
# and appends /etc/hosts for Python processes.
echo "[entrypoint] Starting DNS resolution in background..."
python3 /opt/hermes-scripts/scripts/dns-resolve.py /tmp/dns-resolved.json 2>&1 &
DNS_PID=$!
echo "[entrypoint] DNS resolver PID: $DNS_PID"

# Enable Node.js DNS fix preload for playwright / whatsapp-bridge / web build.
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require /opt/hermes-scripts/scripts/dns-fix.cjs"

# ── Activate virtual environment ─────────────────────────────────────────
if [ -f "${INSTALL_DIR}/.venv/bin/activate" ]; then
  source "${INSTALL_DIR}/.venv/bin/activate"
  echo "[entrypoint] Activated venv: $(which python3)"
fi

# ── Ensure data directories ─────────────────────────────────────────────
mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home}

# ── Bootstrap config files ───────────────────────────────────────────────
if [ ! -f "$HERMES_HOME/.env" ] && [ -f "$INSTALL_DIR/.env.example" ]; then
  cp "$INSTALL_DIR/.env.example" "$HERMES_HOME/.env"
  echo "[entrypoint] Created .env from example"
fi

if [ ! -f "$HERMES_HOME/config.yaml" ] && [ -f "$INSTALL_DIR/cli-config.yaml.example" ]; then
  cp "$INSTALL_DIR/cli-config.yaml.example" "$HERMES_HOME/config.yaml"
  echo "[entrypoint] Created config.yaml from example"
fi

if [ ! -f "$HERMES_HOME/SOUL.md" ] && [ -f "$INSTALL_DIR/docker/SOUL.md" ]; then
  cp "$INSTALL_DIR/docker/SOUL.md" "$HERMES_HOME/SOUL.md"
  echo "[entrypoint] Created SOUL.md from template"
fi

# ── 設定 Hermes 使用 9Router ──────────────────────────────────────────
HERMES_CONFIG="$HERMES_HOME/config.yaml"
if [ -n "${NINEROUTER_API_KEY}" ]; then
    echo "[entrypoint] Configuring Hermes to use 9Router..."
    python3 - <<'EOF'
import os, yaml
config_path = os.environ.get("HERMES_HOME", "/opt/data") + "/config.yaml"
with open(config_path, "r") as f:
    cfg = yaml.safe_load(f) or {}
cfg["provider"] = "openai-compatible"
cfg.setdefault("model", {})["default"] = os.environ.get(
    "NINEROUTER_DEFAULT_MODEL", "kr/claude-sonnet-4.5"
)
cfg["openai_compatible"] = {
    "base_url": "http://localhost:20128/v1",
    "api_key": os.environ.get("NINEROUTER_API_KEY", ""),
}
with open(config_path, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
print("[entrypoint] Hermes config updated to use 9Router")
EOF
fi

# ── Sync bundled skills ──────────────────────────────────────────────────
if [ -d "$INSTALL_DIR/skills" ] && [ -f "$INSTALL_DIR/tools/skills_sync.py" ]; then
    echo "[entrypoint] Syncing skills (with FUSE error protection)..."
    python3 "$INSTALL_DIR/tools/skills_sync.py" 2>&1 || {
        EXIT_CODE=$?
        echo "[entrypoint] Skills sync failed (exit $EXIT_CODE), continuing anyway..."
    }
fi

# ── Build artifacts check ───────────────────────────────────────────────
echo "[entrypoint] Build artifacts check:"
test -f "$INSTALL_DIR/run_agent.py" && echo "  OK run_agent.py" || echo "  INFO: run_agent.py not found"
test -f "$INSTALL_DIR/gateway/run.py" && echo "  OK gateway/run.py" || echo "  INFO: gateway/run.py not found"
test -d "$INSTALL_DIR/web" && echo "  OK web/ dashboard" || echo "  INFO: web/ not found"
command -v hermes >/dev/null 2>&1 && echo "  OK hermes CLI: $(which hermes)" || echo "  INFO: hermes CLI not in PATH"

# Create logs
mkdir -p /opt/data/logs
touch /opt/data/logs/app.log

ENTRYPOINT_END=$(date +%s)
echo "[TIMER] Entrypoint (before sync_hf.py): $((ENTRYPOINT_END - BOOT_START))s"

# ── Start Hermes via sync_hf.py (handles persistence + process management)
echo "[entrypoint] Starting Hermes Agent via sync_hf.py..."
exec /usr/bin/python3 -u /opt/hermes-scripts/scripts/sync_hf.py
