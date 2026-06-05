#!/bin/bash
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/opt/data}"
HERMESFACE_MODE="${HERMESFACE_MODE:-agent}"
NINEROUTER_DATA_DIR="${NINEROUTER_DATA_DIR:-${HERMES_HOME}/9router-data}"
NINEROUTER_DEFAULT_MODEL="${NINEROUTER_DEFAULT_MODEL:-kr/claude-sonnet-4.5}"
NINEROUTER_API_KEY="${NINEROUTER_API_KEY:-sk-local}"
NINEROUTER_JWT_SECRET="${NINEROUTER_JWT_SECRET:-hermesface-change-me}"
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

if [ "$(id -u)" = "0" ]; then
    echo "[entrypoint] Running as root, preparing ${HERMES_HOME}..."
    ensure_data_dirs
    chown -R hermes:hermes "${HERMES_HOME}"
    echo "[entrypoint] ${HERMES_HOME} permissions fixed"
    exec gosu hermes "$0" "$@"
fi

echo "[entrypoint] Waiting for Storage Bucket at ${HERMES_HOME}..."
for i in $(seq 1 10); do
    if touch "${HERMES_HOME}/.bucket_check" 2>/dev/null; then
        rm -f "${HERMES_HOME}/.bucket_check"
        echo "[entrypoint] Bucket ready after ${i}s"
        break
    fi
    sleep 1
done

ensure_data_dirs

echo "[entrypoint] Copying helper scripts into ${HERMES_HOME}/scripts..."
cp -r "${SCRIPTS_SRC}/." "${HERMES_HOME}/scripts/"
chmod +x "${HERMES_HOME}/scripts/"*.sh "${HERMES_HOME}/scripts/"*.py 2>/dev/null || true

echo "[entrypoint] Starting DNS resolution in background..."
python3 /opt/hermes-scripts/scripts/dns-resolve.py /tmp/dns-resolved.json 2>&1 &
DNS_PID=$!
echo "[entrypoint] DNS resolver PID: ${DNS_PID}"

export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require /opt/hermes-scripts/scripts/dns-fix.cjs"
export HERMES_HOME
export NINEROUTER_DEFAULT_MODEL
export NINEROUTER_API_KEY

if [ -f "${INSTALL_DIR}/.venv/bin/activate" ]; then
    # shellcheck disable=SC1091
    source "${INSTALL_DIR}/.venv/bin/activate"
    echo "[entrypoint] Activated venv: $(which python3)"
fi

start_ninerouter() {
    local port="$1"
    local require_api_key="$2"
    local public_base_url="${NINEROUTER_PUBLIC_BASE_URL:-http://localhost:${port}}"

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

if [ "${HERMESFACE_MODE}" = "ninerouter-setup" ]; then
    echo "[entrypoint] HermesFace mode: ninerouter-setup"
    if [ -z "${NINEROUTER_PASSWORD:-}" ]; then
        echo "[entrypoint] WARNING: NINEROUTER_PASSWORD is not set; set one before exposing setup mode."
    fi
    start_ninerouter 7860 true
    wait "${NINEROUTER_PID}"
elif [ "${HERMESFACE_MODE}" = "agent" ]; then
    echo "[entrypoint] HermesFace mode: agent"
    if [ "${NINEROUTER_API_KEY}" = "sk-local" ]; then
        start_ninerouter 20128 false
    else
        start_ninerouter 20128 true
    fi

    echo "[entrypoint] Build artifacts check:"
    test -f "${INSTALL_DIR}/run_agent.py" && echo "  OK run_agent.py" || echo "  INFO: run_agent.py not found"
    test -d "${INSTALL_DIR}/web" && echo "  OK web/ dashboard" || echo "  INFO: web/ not found"
    command -v hermes >/dev/null 2>&1 && echo "  OK hermes CLI: $(which hermes)" || echo "  INFO: hermes CLI not in PATH"

    echo "[entrypoint] Starting Hermes Agent via bucket-only runner..."
    exec /usr/bin/python3 -u /opt/hermes-scripts/scripts/run_hermes.py
else
    echo "[entrypoint] ERROR: unknown HERMESFACE_MODE=${HERMESFACE_MODE}; expected agent or ninerouter-setup" >&2
    exit 1
fi
