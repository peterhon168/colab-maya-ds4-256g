#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

HOST="${MAYA_STUDIO_HOST:-127.0.0.1}"
PORT="${MAYA_STUDIO_PORT:-18765}"
PROXY_PORT="${MAYA_PROXY_PORT:-18766}"
AUTO_ATTACH=1
MODE_WEB=0
MODE_DAEMON=0
NO_OPEN=0

usage() {
    cat << 'EOF'
Usage: bash scripts/launch_studio.sh [OPTIONS]

Launch Maya · Strata Studio (macOS native .app or cross-platform WebUI).

Options:
  --web               Force Python WebUI server and open http://127.0.0.1:<PORT> in browser
  --daemon            Start Python Studio server in the background and return
  --port <PORT>       Control plane port (default: 18765)
  --proxy-port <PORT> Same-origin reverse proxy / OpenAI gateway port (default: 18766)
  --host <HOST>       Bind host (default: 127.0.0.1)
  --no-auto-attach    Do not auto-attach existing Colab sessions on startup
  --no-open           Do not open a browser window automatically
  -h, --help          Show this help message

Without arguments:
  - On macOS: opens MayaStudio.app if built; otherwise falls back to --web.
  - On Linux: starts the WebUI server and opens the browser if available.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --web)
            MODE_WEB=1
            shift
            ;;
        --daemon)
            MODE_DAEMON=1
            shift
            ;;
        --port)
            PORT="${2:?Missing port after --port}"
            shift 2
            ;;
        --port=*)
            PORT="${1#*=}"
            shift
            ;;
        --proxy-port)
            PROXY_PORT="${2:?Missing port after --proxy-port}"
            shift 2
            ;;
        --proxy-port=*)
            PROXY_PORT="${1#*=}"
            shift
            ;;
        --host)
            HOST="${2:?Missing host after --host}"
            shift 2
            ;;
        --host=*)
            HOST="${1#*=}"
            shift
            ;;
        --no-auto-attach)
            AUTO_ATTACH=0
            shift
            ;;
        --no-open)
            NO_OPEN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

resolve_python() {
    if [ -n "${MAYA_PYTHON:-}" ] && [ -x "${MAYA_PYTHON}" ]; then
        echo "${MAYA_PYTHON}"
        return 0
    fi
    for cand in \
        "$(command -v python3 2>/dev/null || true)" \
        "/opt/homebrew/bin/python3" \
        "/usr/local/bin/python3" \
        "$HOME/.local/bin/python3" \
        "/usr/bin/python3"; do
        if [ -n "$cand" ] && [ -x "$cand" ]; then
            if "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
                echo "$cand"
                return 0
            fi
        fi
    done
    return 1
}

is_port_listening() {
    local check_host="$1"
    local check_port="$2"
    "${PYTHON_BIN}" - "$check_host" "$check_port" << 'PY'
import socket, sys
h, p = sys.argv[1], int(sys.argv[2])
try:
    with socket.create_connection((h, p), timeout=0.6):
        sys.exit(0)
except OSError:
    sys.exit(1)
PY
}

wait_for_port() {
    local check_host="$1"
    local check_port="$2"
    local max_tries="${3:-60}"
    local i=0
    while [ "$i" -lt "$max_tries" ]; do
        if is_port_listening "$check_host" "$check_port"; then
            return 0
        fi
        sleep 0.25
        i=$((i + 1))
    done
    return 1
}

open_browser() {
    local url="$1"
    if [ "${NO_OPEN}" -eq 1 ]; then
        return 0
    fi
    if [ "$(uname -s)" = "Darwin" ]; then
        open "${url}" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "${url}" >/dev/null 2>&1 || true
    fi
}

find_macos_app() {
    for candidate in \
        "${PROJECT_ROOT}/MayaStudio.app" \
        "${PROJECT_ROOT}/build/MayaStudio.app" \
        "/Applications/MayaStudio.app"; do
        if [ -d "${candidate}" ]; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

# Default behavior with neither --web nor --daemon
if [ "${MODE_WEB}" -eq 0 ] && [ "${MODE_DAEMON}" -eq 0 ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        if APP_PATH="$(find_macos_app)"; then
            echo "[studio] Launching macOS desktop app: ${APP_PATH}"
            open "${APP_PATH}"
            exit 0
        else
            echo "[studio] MayaStudio.app not found (tip: run 'bash macos_app/build_macos_app.sh' to build the native .app)."
            echo "[studio] Falling back to WebUI mode..."
            MODE_WEB=1
        fi
    else
        MODE_WEB=1
    fi
fi

PYTHON_BIN="$(resolve_python || true)"
if [ -z "${PYTHON_BIN}" ]; then
    echo "[studio] ERROR: Python 3.9+ not found. Set MAYA_PYTHON or install python3." >&2
    exit 1
fi

if [ ! -f "${PROJECT_ROOT}/studio/__main__.py" ]; then
    echo "[studio] ERROR: Missing studio/__main__.py under ${PROJECT_ROOT}" >&2
    exit 1
fi

STUDIO_URL="http://${HOST}:${PORT}"
PROXY_URL="http://${HOST}:${PROXY_PORT}"

# Never kill or disrupt an existing running Studio service
if is_port_listening "${HOST}" "${PORT}"; then
    echo "[studio] Port ${HOST}:${PORT} is already listening; reusing the active service (external workflows untouched)."
    echo "[studio] Studio UI: ${STUDIO_URL}"
    echo "[studio] OpenAI Proxy Gateway: ${PROXY_URL}/v1"
    if [ "${MODE_WEB}" -eq 1 ]; then
        open_browser "${STUDIO_URL}"
    fi
    exit 0
fi

export MAYA_STUDIO_ROOT="${PROJECT_ROOT}"
export PYTHONPATH="${PROJECT_ROOT}${PYTHONPATH:+:${PYTHONPATH}}"
export PYTHONUNBUFFERED=1

STUDIO_ARGS=(
    -m studio
    --host "${HOST}"
    --port "${PORT}"
    --proxy-port "${PROXY_PORT}"
)
if [ "${AUTO_ATTACH}" -eq 1 ]; then
    STUDIO_ARGS+=(--auto-attach)
fi

cd "${PROJECT_ROOT}"

if [ "${MODE_DAEMON}" -eq 1 ]; then
    LOG_FILE="/tmp/maya-strata-studio-${PORT}.log"
    nohup "${PYTHON_BIN}" "${STUDIO_ARGS[@]}" > "${LOG_FILE}" 2>&1 &
    SERVER_PID=$!
    if wait_for_port "${HOST}" "${PORT}" 60; then
        echo "[studio] Started Maya · Strata Studio daemon (PID=${SERVER_PID})"
        echo "[studio] Studio UI: ${STUDIO_URL}"
        echo "[studio] OpenAI Proxy Gateway: ${PROXY_URL}/v1"
        echo "[studio] Log: ${LOG_FILE}"
        if [ "${MODE_WEB}" -eq 1 ]; then
            open_browser "${STUDIO_URL}"
        fi
        exit 0
    else
        echo "[studio] ERROR: Studio daemon failed to bind ${HOST}:${PORT}. Recent log:" >&2
        tail -n 30 "${LOG_FILE}" >&2 || true
        exit 1
    fi
fi

# Foreground --web mode
echo "[studio] Starting Maya · Strata Studio on ${STUDIO_URL} (proxy ${PROXY_URL}/v1)..."
"${PYTHON_BIN}" "${STUDIO_ARGS[@]}" &
SERVER_PID=$!

cleanup_fg() {
    if kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
        kill -TERM "${SERVER_PID}" >/dev/null 2>&1 || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
}
trap cleanup_fg INT TERM

if wait_for_port "${HOST}" "${PORT}" 60; then
    echo "[studio] Ready -> ${STUDIO_URL}"
    open_browser "${STUDIO_URL}"
else
    echo "[studio] WARNING: Timed out waiting for ${STUDIO_URL}; check output above." >&2
fi

wait "${SERVER_PID}"
