#!/usr/bin/env bash
# Share account-agnostic Claude Code config between two CLAUDE_CONFIG_DIRs via symlinks.
# Source stays canonical (~/.claude), target (~/.claude2) gets symlinks.
# Credentials & .claude.json are NEVER touched — they must stay per-account.
#
# Usage: share-claude-config.sh [--dry-run] [SOURCE] [TARGET]
#   default SOURCE=~/.claude TARGET=~/.claude2

set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

SOURCE="${1:-$HOME/.claude}"
TARGET="${2:-$HOME/.claude2}"

SHARED_ITEMS=(
  projects            # sessions + memory
  CLAUDE.md           # global instructions
  settings.json       # hooks, permissions, env, model
  settings.local.json
  skills
  agents
  hooks
  plugins
  plans
  tasks
  file-history        # rewind/checkpoint — must follow shared sessions
  history.jsonl       # command history
  keybindings.json
  statusline-command.sh
)

[[ -d "$SOURCE" ]] || { echo "ERROR: source not found: $SOURCE" >&2; exit 1; }
[[ -d "$TARGET" ]] || { echo "ERROR: target not found: $TARGET" >&2; exit 1; }
[[ "$(cd "$SOURCE" && pwd)" == "$(cd "$TARGET" && pwd)" ]] && { echo "ERROR: source == target" >&2; exit 1; }

BACKUP_DIR="$TARGET/.share-backup-$(date +%Y%m%d%H%M%S)"

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

linked=0 skipped=0 backed_up=0

for item in "${SHARED_ITEMS[@]}"; do
  src="$SOURCE/$item"
  dst="$TARGET/$item"

  if [[ ! -e "$src" ]]; then
    echo "skip (no source): $item"
    ((skipped++)) || true
    continue
  fi

  # already correct symlink → idempotent skip
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    echo "ok (already linked): $item"
    ((skipped++)) || true
    continue
  fi

  # existing real file/dir or stale symlink → back up, don't delete
  if [[ -e "$dst" || -L "$dst" ]]; then
    run mkdir -p "$BACKUP_DIR"
    run mv "$dst" "$BACKUP_DIR/$item"
    echo "backup: $item -> $BACKUP_DIR/$item"
    ((backed_up++)) || true
  fi

  run ln -s "$src" "$dst"
  echo "link: $dst -> $src"
  ((linked++)) || true
done

echo
echo "done: $linked linked, $backed_up backed up, $skipped skipped"
[[ $backed_up -gt 0 && $DRY_RUN -eq 0 ]] && echo "backups in: $BACKUP_DIR"
echo "NOT shared (per-account, by design): .claude.json, credentials/keychain, cache, statsig, telemetry"
