#!/usr/bin/env bash
set -euo pipefail

SKILL_SRC="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_NAME="colab-maya-ds4-256g"
TARGET_BASE="$HOME/.gemini/config/skills/$SKILL_NAME"

mkdir -p "$HOME/.gemini/config/skills" "$HOME/.agents/skills" "$HOME/.codex/skills" "$HOME/.claude/skills"

if [ "$SKILL_SRC" != "$TARGET_BASE" ]; then
  rm -rf "$TARGET_BASE"
  cp -R "$SKILL_SRC" "$TARGET_BASE"
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
