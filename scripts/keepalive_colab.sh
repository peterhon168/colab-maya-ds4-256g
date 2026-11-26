#!/usr/bin/env bash
# Colab Jupyter Kernel 防休眠保活 + 可选同步 Cloudflare 隧道 URL 到本地客户端配置
set -u

SESSION="${1:-easycolab}"
INTERVAL_SEC="${2:-720}" # 默认每 12 分钟向 Colab Jupyter Kernel 发送一次心跳，防止 60 分钟空闲被 Colab 回收

PI_MODELS_JSON="${PI_MODELS_JSON:-$HOME/.pi/agent/models.json}"
PI_PROVIDER_KEY="${PI_PROVIDER_KEY:-A100}"
PI_WEB_URL="${PI_WEB_URL:-http://127.0.0.1:30141}"
MAYA_API_KEY_FILE="${MAYA_API_KEY_FILE:-$HOME/.config/maya-gcs/maya-api-key}"

echo "[keepalive] 已启动 Colab Session ($SESSION) 内核防休眠保活守护 (间隔: ${INTERVAL_SEC}s)..."

SYNCED_URL=""

while true; do
  OUT="$(python3 - "$SESSION" << 'PY' 2>&1
import os, signal, subprocess, sys
sess = sys.argv[1]
def run_bounded(cmd, stdin_data=None, timeout=90):
    p = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE if stdin_data is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    try:
        out, _ = p.communicate(stdin_data, timeout=timeout)
        return p.returncode, out or ""
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except Exception:
            p.kill()
        p.communicate()
        return 124, "TIMEOUT"

run_bounded(["colab", "sessions"], timeout=30)
script = """!pgrep -f "maya.py|maya-ds4|strata" >/dev/null && echo "MAYA_ALIVE=1" || echo "MAYA_ALIVE=0"
!grep -hoE "https://[a-zA-Z0-9-]+\\.trycloudflare\\.com" /content/project-maya/cloudflared.log /tmp/cloudflared.log 2>/dev/null | tail -n 1
"""
rc, out = run_bounded(["colab", "exec", "-s", sess, "--timeout", "60"], stdin_data=script, timeout=90)
print(out, end="")
PY
)"
  if echo "$OUT" | grep -q "TIMEOUT"; then
    echo "[keepalive] $(date '+%Y-%m-%d %H:%M:%S') 心跳超时 (90s)，将在下个周期重试。"
    sleep 60
    continue
  fi
  if echo "$OUT" | grep -q "not found\|No active sessions"; then
    echo "[keepalive] Session '$SESSION' 已结束或释放，退出保活守护。"
    exit 0
  fi

  if echo "$OUT" | grep -q "MAYA_ALIVE=0"; then
    echo "[keepalive] 远端 maya.py / maya-ds4 未运行，退出保活守护。"
    exit 0
  fi

  TUNNEL_URL="$(echo "$OUT" | grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" | tail -n 1 || true)"
  if [ -n "$TUNNEL_URL" ] && [ "$TUNNEL_URL" != "$SYNCED_URL" ]; then
    echo "[keepalive] 检测到 Cloudflare 隧道 URL: ${TUNNEL_URL}"
    if [ -f "$PI_MODELS_JSON" ]; then
      echo "[keepalive] 正在同步本地配置 ($PI_MODELS_JSON, provider=$PI_PROVIDER_KEY)..."
      python3 - "$PI_MODELS_JSON" "$TUNNEL_URL" "$PI_PROVIDER_KEY" "$PI_WEB_URL" "$MAYA_API_KEY_FILE" << 'PY' || true
import json, os, sys, urllib.request
path, url, pkey, web_url, api_key_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].rstrip("/"), sys.argv[5]
api_key = ""
if api_key_file and os.path.isfile(api_key_file):
    try:
        api_key = open(api_key_file, "r", encoding="utf-8").read().strip()
    except OSError:
        api_key = ""
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
if "providers" in cfg and pkey in cfg["providers"]:
    cfg["providers"][pkey]["baseUrl"] = f"{url}/v1"
    if api_key:
        cfg["providers"][pkey]["apiKey"] = api_key
    for m in cfg["providers"][pkey].get("models", []):
        m["maxTokens"] = max(int(m.get("maxTokens") or 0), 65536)
        if "image" not in m.get("input", []):
            m["input"] = ["text", "image"]
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    if web_url:
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            req = urllib.request.Request(
                f"{web_url}/api/models-config",
                data=json.dumps(cfg).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="PUT",
            )
            opener.open(req, timeout=5).read()
            req2 = urllib.request.Request(
                f"{web_url}/api/models/refresh",
                data=b"{}",
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            opener.open(req2, timeout=5).read()
        except Exception:
            pass
PY
    fi
    SYNCED_URL="$TUNNEL_URL"
  fi

  echo "[keepalive] $(date '+%Y-%m-%d %H:%M:%S') Session '$SESSION' 存活 (${SYNCED_URL:-等待隧道})"
  sleep "$INTERVAL_SEC"
done
