#!/usr/bin/env bash
# Installs this repo's Claude Code configuration into the active profile.
#
# USAGE
#   ./setup.sh
#
# Honors CLAUDE_CONFIG_DIR, so it works for alternate profiles too:
#   CLAUDE_CONFIG_DIR=~/.work-claude ./setup.sh
# A profile mirrored by share-claude-config.sh (symlinks) is refused —
# run setup.sh against its source profile instead.
#
# WHAT IT DOES
#   1. settings.json        -> deep-merged into <profile>/settings.json (jq).
#                              Keys not in the repo file (e.g. the SessionStart
#                              hook auto-added by context-mode) are preserved.
#                              Hook lists are merged per event: the repo's hook
#                              entries replace entries with the same command,
#                              other hooks in the same event are kept.
#                              Script paths are rewritten into <profile>.
#                              A backup is taken first (newest 5 kept).
#   2. statusline-command.sh -> copied + chmod +x
#      hooks/auto-session-title.py -> copied + chmod +x
#   3. CLAUDE.md             -> copied
#   4. keybindings.json      -> copied
#   5. Requires jq; warns if mdformat / python3 >= 3.8 are missing.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_DIR="${CLAUDE_DIR/#\~/$HOME}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (brew install jq)"; exit 1; }

for item in settings.json statusline-command.sh hooks CLAUDE.md keybindings.json; do
  if [ -L "$CLAUDE_DIR/$item" ]; then
    echo "ERROR: $CLAUDE_DIR/$item is a symlink -> $(readlink "$CLAUDE_DIR/$item")"
    echo "       This profile is shared (share-claude-config.sh); run setup.sh against the source profile."
    exit 1
  fi
done

mkdir -p "$CLAUDE_DIR/hooks"

# 1. settings.json — deep merge (repo values win on conflicting leaves,
#    everything else in the existing file is kept).
TARGET="$CLAUDE_DIR/settings.json"
trap 'rm -f "$TARGET.tmp"' EXIT

MERGE='
def norm: gsub("\\$HOME"; $home) | gsub("~/"; $home + "/");
def cmds: [.[]?.hooks[]?.command | norm];
($new[0]
  | ((.. | strings) |= gsub("\\$HOME/\\.claude/"; $dir + "/"))
  | .statusLine.command = $sl) as $repo
| ($old * ($repo | del(.hooks)))
| .hooks = reduce (($repo.hooks // {}) | to_entries[]) as $e (($old.hooks // {});
    ($e.value | cmds) as $rc
    | .[$e.key] = ([(.[$e.key] // [])[] | select(any(.hooks[]?.command | norm; IN($rc[])) | not)] + $e.value))
'

if [ -e "$TARGET" ]; then
  jq -e 'type == "object"' "$TARGET" >/dev/null 2>&1 || {
    echo "ERROR: $TARGET is not a JSON object — fix or remove it, then re-run"; exit 1; }
  OLD_JSON="$(cat "$TARGET")"
  cp "$TARGET" "$TARGET.bak.$(date +%Y%m%d%H%M%S).$$"
  ls -1t "$TARGET".bak.* 2>/dev/null | tail -n +6 | while IFS= read -r f; do rm -f -- "$f"; done
  VERB="merged   settings.json (backup taken)"
else
  OLD_JSON='{}'
  VERB="created  settings.json"
fi
jq -n --argjson old "$OLD_JSON" --slurpfile new "$REPO_DIR/settings.json" \
  --arg home "$HOME" --arg dir "$CLAUDE_DIR" \
  --arg sl "bash \"$CLAUDE_DIR/statusline-command.sh\"" \
  "$MERGE" > "$TARGET.tmp"
mv -f "$TARGET.tmp" "$TARGET"
echo "$VERB"

# 2. status line script + auto session title hook
cp "$REPO_DIR/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"
chmod +x "$CLAUDE_DIR/statusline-command.sh"
echo "copied   statusline-command.sh"

cp "$REPO_DIR/hooks/auto-session-title.py" "$CLAUDE_DIR/hooks/auto-session-title.py"
chmod +x "$CLAUDE_DIR/hooks/auto-session-title.py"
echo "copied   hooks/auto-session-title.py"

# 3. global memory
cp "$REPO_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
echo "copied   CLAUDE.md"

# 4. keybindings
cp "$REPO_DIR/keybindings.json" "$CLAUDE_DIR/keybindings.json"
echo "copied   keybindings.json"

# 5. dependency warnings (non-fatal — both hooks are no-ops without them)
[ -x "$HOME/.local/bin/mdformat" ] || \
  echo "WARN: ~/.local/bin/mdformat not found — md auto-format hook will be a no-op (uv tool install mdformat)"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null || \
  echo "WARN: python3 >= 3.8 not found — auto session title hook will be a no-op (brew install python)"

echo "done -> $CLAUDE_DIR (restart claude to apply)"
