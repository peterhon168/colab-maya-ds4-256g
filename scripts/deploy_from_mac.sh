#!/usr/bin/env bash
set -euo pipefail

SESSION="${1:-easycolab}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RES_DIR="$(cd "$SCRIPT_DIR/../resources" && pwd)"

echo "[Mac] 正在刷新 Colab 会话并上传预编译运行包 (免编译、免挂载 Google Drive、免打包索引) 至 Colab ($SESSION)..."
colab sessions >/dev/null
colab upload -s "$SESSION" "$RES_DIR/maya-g4-runtime.tar.gz" /tmp/maya-g4-runtime.tar.gz
if [ -f "$RES_DIR/maya-a100-sm80-build.tar.gz" ]; then
  colab upload -s "$SESSION" "$RES_DIR/maya-a100-sm80-build.tar.gz" /tmp/maya-a100-sm80-build.tar.gz
fi
colab upload -s "$SESSION" "$RES_DIR/maya-ds4.json" /tmp/maya-ds4.json
colab upload -s "$SESSION" "$RES_DIR/pack-meta-256g.tar.gz" /tmp/pack-meta-256g.tar.gz
colab upload -s "$SESSION" "$SCRIPT_DIR/start_g4_256g.sh" /tmp/start_g4_256g.sh
SRC_DIR="$(cd "$SCRIPT_DIR/../src" 2>/dev/null && pwd || true)"
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/hf_ro_fuse.c" ]; then
  colab upload -s "$SESSION" "$SRC_DIR/hf_ro_fuse.c" /tmp/hf_ro_fuse.c
fi
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/gcs_tls_pread.c" ]; then
  colab upload -s "$SESSION" "$SRC_DIR/gcs_tls_pread.c" /tmp/gcs_tls_pread.c
fi

# 凭据优先级: 环境变量 > ~/.config/maya-gcs/ (推荐，独立于 Git 仓库之外) > 本地被 .gitignore 忽略的 resources/
GCS_KEY_FILE=""
if [ -n "${MAYA_GCS_KEY_FILE:-}" ] && [ -f "$MAYA_GCS_KEY_FILE" ]; then
  GCS_KEY_FILE="$MAYA_GCS_KEY_FILE"
elif [ -f "$HOME/.config/maya-gcs/gcs-key.json" ]; then
  GCS_KEY_FILE="$HOME/.config/maya-gcs/gcs-key.json"
elif [ -f "$RES_DIR/gcs-key.json" ]; then
  GCS_KEY_FILE="$RES_DIR/gcs-key.json"
fi

if [ -n "$GCS_KEY_FILE" ]; then
  colab upload -s "$SESSION" "$GCS_KEY_FILE" /tmp/gcs-key.json
  GCS_BUCKET="${MAYA_GCS_BUCKET:-$(cat "$HOME/.config/maya-gcs/bucket" "$RES_DIR/gcs-bucket" 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)}"
  if [ -n "$GCS_BUCKET" ]; then
    TMP_BUCKET="/tmp/maya-gcs-bucket.$$"
    umask 077
    printf '%s\n' "$GCS_BUCKET" > "$TMP_BUCKET"
    colab upload -s "$SESSION" "$TMP_BUCKET" /tmp/gcs-bucket
    rm -f "$TMP_BUCKET"
  fi
fi

HF_TOKEN_FILE=""
if [ -n "${MAYA_HF_TOKEN_FILE:-}" ] && [ -f "$MAYA_HF_TOKEN_FILE" ]; then
  HF_TOKEN_FILE="$MAYA_HF_TOKEN_FILE"
elif [ -n "${HF_TOKEN_FILE:-}" ] && [ -f "$HF_TOKEN_FILE" ]; then
  HF_TOKEN_FILE="$HF_TOKEN_FILE"
elif [ -f "$HOME/.config/maya-gcs/hf-token" ]; then
  HF_TOKEN_FILE="$HOME/.config/maya-gcs/hf-token"
elif [ -f "$RES_DIR/hf-token" ]; then
  HF_TOKEN_FILE="$RES_DIR/hf-token"
fi

if [ -n "$HF_TOKEN_FILE" ]; then
  colab upload -s "$SESSION" "$HF_TOKEN_FILE" /tmp/hf-token
elif [ -n "${HF_TOKEN:-}" ]; then
  TMP_HF="/tmp/maya-hf-token.$$"
  umask 077
  printf '%s' "$HF_TOKEN" > "$TMP_HF"
  colab upload -s "$SESSION" "$TMP_HF" /tmp/hf-token
  rm -f "$TMP_HF"
fi

# 可选公网 API 网关鉴权密钥 (保护 *.trycloudflare.com 不被未授权访问)
MAYA_API_KEY_FILE_PATH=""
if [ -n "${MAYA_API_KEY_FILE:-}" ] && [ -f "$MAYA_API_KEY_FILE" ]; then
  MAYA_API_KEY_FILE_PATH="$MAYA_API_KEY_FILE"
elif [ -f "$HOME/.config/maya-gcs/maya-api-key" ]; then
  MAYA_API_KEY_FILE_PATH="$HOME/.config/maya-gcs/maya-api-key"
elif [ -f "$RES_DIR/maya-api-key" ]; then
  MAYA_API_KEY_FILE_PATH="$RES_DIR/maya-api-key"
fi

if [ -n "$MAYA_API_KEY_FILE_PATH" ]; then
  colab upload -s "$SESSION" "$MAYA_API_KEY_FILE_PATH" /tmp/maya-api-key
elif [ -n "${MAYA_API_KEY:-}" ]; then
  TMP_API="/tmp/maya-api-key.$$"
  umask 077
  printf '%s' "$MAYA_API_KEY" > "$TMP_API"
  colab upload -s "$SESSION" "$TMP_API" /tmp/maya-api-key
  rm -f "$TMP_API"
fi

echo "[Mac] 正在启动远端自动拉取与部署流程..."
colab exec -s "$SESSION" --timeout 1800 << 'EOF'
!mkdir -p /content/project-maya
!tar -xzf /tmp/maya-g4-runtime.tar.gz -C /content/project-maya/
!cp -f /tmp/maya-ds4.json /content/project-maya/maya-ds4.json
!cp -f /tmp/pack-meta-256g.tar.gz /content/project-maya/pack-meta-256g.tar.gz
!chmod +x /tmp/start_g4_256g.sh
!bash /tmp/start_g4_256g.sh
EOF

echo "[Mac] 正在后台启动 Colab Jupyter 内核防休眠保活与可选本地配置同步守护..."
chmod +x "$SCRIPT_DIR/keepalive_colab.sh"
pkill -f "keepalive_colab.sh $SESSION" 2>/dev/null || true
nohup bash "$SCRIPT_DIR/keepalive_colab.sh" "$SESSION" 720 > "/tmp/colab-keepalive-${SESSION}.log" 2>&1 &
echo "[Mac] 保活守护已启动 (日志: /tmp/colab-keepalive-${SESSION}.log)"
