#!/usr/bin/env bash
set -euo pipefail

SKILL_SRC="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_NAME="colab-maya-ds4-256g"
TARGET_BASE="$HOME/.gemini/config/skills/$SKILL_NAME"

mkdir -p "$HOME/.gemini/config/skills" "$HOME/.agents/skills" "$HOME/.codex/skills" "$HOME/.claude/skills"

if [ "$SKILL_SRC" != "$TARGET_BASE" ]; then
  STASH_DIR=""
  if [ -d "$TARGET_BASE/resources" ]; then
    STASH_DIR="$(mktemp -d)"
    for cred in gcs-key.json gcs-bucket hf-token; do
      if [ -f "$TARGET_BASE/resources/$cred" ]; then
        cp -p "$TARGET_BASE/resources/$cred" "$STASH_DIR/$cred"
      fi
    done
  fi

  rm -rf "$TARGET_BASE"
  mkdir -p "$TARGET_BASE"
  for item in SKILL.md README.md LICENSE docs resources scripts src; do
    if [ -e "$SKILL_SRC/$item" ]; then
      cp -R "$SKILL_SRC/$item" "$TARGET_BASE/"
    fi
  done

  if [ -n "$STASH_DIR" ] && [ -d "$STASH_DIR" ]; then
    mkdir -p "$TARGET_BASE/resources"
    for cred in gcs-key.json gcs-bucket hf-token; do
      if [ -f "$STASH_DIR/$cred" ] && [ ! -f "$TARGET_BASE/resources/$cred" ]; then
        cp -p "$STASH_DIR/$cred" "$TARGET_BASE/resources/$cred"
        chmod 600 "$TARGET_BASE/resources/$cred"
      fi
    done
    rm -rf "$STASH_DIR"
  fi
fi

chmod +x "$TARGET_BASE/scripts/"*.sh

for dir in "$HOME/.agents/skills" "$HOME/.codex/skills" "$HOME/.claude/skills"; do
  ln -sfn "$TARGET_BASE" "$dir/$SKILL_NAME"
done

echo "✅ Skill '$SKILL_NAME' 已安装并挂载至:"
echo "  - $TARGET_BASE"
echo "  - $HOME/.agents/skills/$SKILL_NAME"
echo "  - $HOME/.codex/skills/$SKILL_NAME"
echo "  - $HOME/.claude/skills/$SKILL_NAME"
