#!/bin/bash
set -euo pipefail
umask 000

# ── 環境變數（加上 export，確保 gosu 後的 child process 繼承） ──────────────
export HERMES_HOME="${HERMES_HOME:-/opt/data}"
export HERMESFACE_MODE="${HERMESFACE_MODE:-agent}"
export NINEROUTER_DATA_DIR="${NINEROUTER_DATA_DIR:-${HERMES_HOME}/9router-data}"
export NINEROUTER_DEFAULT_MODEL="${NINEROUTER_DEFAULT_MODEL:-kr/claude-sonnet-4.5}"
export NINEROUTER_API_KEY="${NINEROUTER_API_KEY:-sk-local}"
export NINEROUTER_JWT_SECRET="${NINEROUTER_JWT_SECRET:-hermesface-change-me}"
SCRIPTS_SRC="/opt/hermes-scripts/scripts"
INSTALL_DIR="/opt/hermes"

ensure_data_dirs() {
  mkdir -p "${NINEROUTER_DATA_DIR}/db" \
           "${NINEROUTER_DATA_DIR}" \
           "${HERMES_HOME}/scripts" \
           "${HERMES_HOME}/cron" \
           "${HERMES_HOME}/sessions" \
           "${HERMES_HOME}/logs" \
           "${HERMES_HOME}/hooks" \
           "${HERMES_HOME}/memories" \
           "${HERMES_HOME}/skills" \
           "${HERMES_HOME}/skins" \
           "${HERMES_HOME}/plans" \
           "${HERMES_HOME}/workspace" \
           "${HERMES_HOME}/home"
}

# ── Root 降權 ──────────────────────────────────────────────────────────────
if [ "$(id -u)" = "0" ]; then
  echo "[entrypoint] Running as root, preparing ${HERMES_HOME}..."
  ensure_data_dirs
  # 複製輔助腳本（在 root 階段執行，避免降權後權限不足）
  echo "[entrypoint] Copying helper scripts into ${HERMES_HOME}/scripts..."
  cp -r "${SCRIPTS_SRC}/." "${HERMES_HOME}/scripts/"
  chmod +x "${HERMES_HOME}/scripts/"*.sh "${HERMES_HOME}/scripts/"*.py 2>/dev/null || true
  # 確保 /opt/data 完整可讀寫（僅修正權限不足的文件，避免全量遞迴）
  echo "[entrypoint] Fixing permissions on ${HERMES_HOME}..."
  chown -R hermes:hermes "${HERMES_HOME}" 2>/dev/null || true
  # 只 chmod 缺少 write 權限的檔案/目錄（比 chmod -R 快得多）
  find "${HERMES_HOME}" ! -perm -002 -exec chmod 777 {} + 2>/dev/null || true

  exec gosu hermes "$0" "$@"
fi

# ── 等待 Storage Bucket 就緒（帶失敗退出） ────────────────────────────────
echo "[entrypoint] Waiting for Storage Bucket at ${HERMES_HOME}..."
BUCKET_READY=0
for i in $(seq 1 10); do
  if touch "${HERMES_HOME}/.bucket_check" 2>/dev/null; then
    rm -f "${HERMES_HOME}/.bucket_check"
    echo "[entrypoint] Bucket ready after ${i}s"
    BUCKET_READY=1
    break
  fi
  sleep 1
done

# ★ 修正 1：bucket 未就緒時明確報錯退出，不再靜默繼續
if [ "${BUCKET_READY}" -eq 0 ]; then
  echo "[entrypoint] ERROR: Storage Bucket at ${HERMES_HOME} not writable after 10s" >&2
  exit 1
fi

ensure_data_dirs

# ── 輔助腳本已在 root 階段複製，此處僅做 chmod 保險 ─────────────────────
if ! chmod +x "${HERMES_HOME}/scripts/"*.sh "${HERMES_HOME}/scripts/"*.py 2>/dev/null; then
  echo "[entrypoint] WARNING: Some scripts could not be made executable" >&2
fi

# ── DNS 背景解析（等待結果後再繼續） ─────────────────────────────────────
echo "[entrypoint] Starting DNS resolution in background..."
python3 /opt/hermes-scripts/scripts/dns-resolve.py /tmp/dns-resolved.json 2>&1 &
DNS_PID=$!
echo "[entrypoint] DNS resolver PID: ${DNS_PID}"

# ★ 修正 3：等待 dns-resolved.json 生成，最多 15s，避免後續讀取競態
DNS_WAIT=0
while [ ! -f /tmp/dns-resolved.json ] && [ "${DNS_WAIT}" -lt 15 ]; do
  sleep 1
  DNS_WAIT=$((DNS_WAIT + 1))
done
if [ ! -f /tmp/dns-resolved.json ]; then
  echo "[entrypoint] WARNING: DNS resolution did not complete within 15s, continuing anyway" >&2
fi

export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require /opt/hermes-scripts/scripts/dns-fix.cjs"

# ── 啟用 venv ─────────────────────────────────────────────────────────────
if [ -f "${INSTALL_DIR}/.venv/bin/activate" ]; then
  # shellcheck disable=SC1091
  source "${INSTALL_DIR}/.venv/bin/activate"
  echo "[entrypoint] Activated venv: $(which python3)"
fi

# ── 9Router 啟動函式 ───────────────────────────────────────────────────────
start_ninerouter() {
  local port="$1"
  local require_api_key="$2"
  local public_base_url="${NINEROUTER_PUBLIC_BASE_URL:-http://localhost:${port}}"
  # ★ 修正 4：明確宣告 NINEROUTER_PID 為全域（避免函式提早 return 時未賦值）
  NINEROUTER_PID=""
  echo "[entrypoint] Starting 9Router on port ${port} (data=${NINEROUTER_DATA_DIR})..."
  PORT="${port}" \
  HOSTNAME=0.0.0.0 \
  NODE_ENV=production \
  NEXT_PUBLIC_BASE_URL="${public_base_url}" \
  DATA_DIR="${NINEROUTER_DATA_DIR}" \
  JWT_SECRET="${NINEROUTER_JWT_SECRET}" \
  INITIAL_PASSWORD="${NINEROUTER_PASSWORD:-}" \
  REQUIRE_API_KEY="${require_api_key}" \
  AUTH_COOKIE_SECURE=false \
  node /opt/9router/server.js &
  NINEROUTER_PID=$!
  echo "[entrypoint] 9Router PID: ${NINEROUTER_PID}"
  for i in $(seq 1 30); do
    if curl -sf "http://localhost:${port}/api/health" >/dev/null 2>&1; then
      echo "[entrypoint] 9Router ready after ${i}s"
      return 0
    fi
    sleep 1
  done
  echo "[entrypoint] ERROR: 9Router did not become ready on port ${port}" >&2
  return 1
}

# ── 主邏輯 ────────────────────────────────────────────────────────────────
if [ "${HERMESFACE_MODE}" = "ninerouter-setup" ]; then
  echo "[entrypoint] HermesFace mode: ninerouter-setup"
  if [ -z "${NINEROUTER_PASSWORD:-}" ]; then
    echo "[entrypoint] WARNING: NINEROUTER_PASSWORD is not set; set one before exposing setup mode."
  fi
  # ★ 修正 4 續：確認 start_ninerouter 成功後再 wait
  start_ninerouter 7860 true
  if [ -z "${NINEROUTER_PID}" ]; then
    echo "[entrypoint] ERROR: 9Router failed to start" >&2
    exit 1
  fi
  wait "${NINEROUTER_PID}"
elif [ "${HERMESFACE_MODE}" = "agent" ]; then
  echo "[entrypoint] HermesFace mode: agent"
  if [ "${NINEROUTER_API_KEY}" = "sk-local" ]; then
    start_ninerouter 20128 false
  else
    start_ninerouter 20128 true
  fi
  echo "[entrypoint] Build artifacts check:"
  test -f "${INSTALL_DIR}/run_agent.py"  && echo "  OK  run_agent.py"       || echo "  INFO: run_agent.py not found"
  test -d "${INSTALL_DIR}/web"           && echo "  OK  web/ dashboard"      || echo "  INFO: web/ not found"
  command -v hermes >/dev/null 2>&1      && echo "  OK  hermes CLI: $(which hermes)" || echo "  INFO: hermes CLI not in PATH"
  echo "[entrypoint] Starting Hermes Agent via bucket-only runner..."
  exec /usr/bin/python3 -u /opt/hermes-scripts/scripts/run_hermes.py
else
  echo "[entrypoint] ERROR: unknown HERMESFACE_MODE=${HERMESFACE_MODE}; expected agent or ninerouter-setup" >&2
  exit 1
fi
