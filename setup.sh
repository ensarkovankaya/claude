#!/usr/bin/env bash
# Installs this repo's Claude Code configuration into the active profile.
#
# USAGE
#   ./setup.sh
#
# Honors CLAUDE_CONFIG_DIR, so it works for alternate profiles too:
#   CLAUDE_CONFIG_DIR=~/.claude2 ./setup.sh
#
# WHAT IT DOES
#   1. settings.json        -> deep-merged into <profile>/settings.json (jq).
#                              Existing extra fields (e.g. the SessionStart
#                              hook auto-added by context-mode) are preserved;
#                              only keys defined in the repo file are applied.
#                              A timestamped backup is taken first.
#   2. statusline-command.sh -> copied + chmod +x
#   3. CLAUDE.md             -> copied
#   4. keybindings.json      -> copied
#   5. Warns if jq / mdformat are missing.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (brew install jq)"; exit 1; }

mkdir -p "$CLAUDE_DIR"

# 1. settings.json — deep merge (repo values win on conflicting leaves,
#    everything else in the existing file is kept). The statusLine command
#    is rewritten to point into the active profile dir, so alternate
#    profiles (CLAUDE_CONFIG_DIR) get a working status line too.
TARGET="$CLAUDE_DIR/settings.json"
STATUSLINE_CMD="bash $CLAUDE_DIR/statusline-command.sh"
if [ -f "$TARGET" ]; then
  cp "$TARGET" "$TARGET.bak.$(date +%Y%m%d%H%M%S)"
  jq -s --arg sl "$STATUSLINE_CMD" \
    '.[0] * .[1] | .statusLine.command = $sl' \
    "$TARGET" "$REPO_DIR/settings.json" > "$TARGET.tmp"
  mv -f "$TARGET.tmp" "$TARGET"
  echo "merged   settings.json (backup taken)"
else
  jq --arg sl "$STATUSLINE_CMD" '.statusLine.command = $sl' \
    "$REPO_DIR/settings.json" > "$TARGET"
  echo "created  settings.json"
fi

# 2. status line script
cp "$REPO_DIR/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"
chmod +x "$CLAUDE_DIR/statusline-command.sh"
echo "copied   statusline-command.sh"

# 3. global memory
cp "$REPO_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
echo "copied   CLAUDE.md"

# 4. keybindings
cp "$REPO_DIR/keybindings.json" "$CLAUDE_DIR/keybindings.json"
echo "copied   keybindings.json"

# 5. dependency warnings (non-fatal — the mdformat hook fails silently anyway)
[ -x "$HOME/.local/bin/mdformat" ] || \
  echo "WARN: ~/.local/bin/mdformat not found — md auto-format hook will be a no-op (uv tool install mdformat)"

echo "done -> $CLAUDE_DIR (restart claude to apply)"
