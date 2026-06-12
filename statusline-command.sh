#!/usr/bin/env bash
# Claude Code status line script.
#
# INSTALL
#   Copy to ~/.claude/statusline-command.sh and make it executable:
#     cp statusline-command.sh ~/.claude/statusline-command.sh
#     chmod +x ~/.claude/statusline-command.sh
#   It is wired up by the "statusLine" block in ~/.claude/settings.json.
#
# WHAT IT DOES
#   On every refresh, Claude Code pipes a JSON payload (model, cwd, ...)
#   to this script's stdin. The script prints a single line:
#     <model name>  <current dir basename>  <git branch>
#   Colors: dim cyan / dim yellow / dim magenta. The branch segment is
#   omitted when the cwd is not inside a git repository; on a detached
#   HEAD it falls back to the short commit SHA.
#
# REQUIRES: jq

# Read the full JSON payload Claude Code sends on stdin
input=$(cat)

# Extract model display name and current working directory from the payload
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
cwd=$(echo "$input" | jq -r '.cwd // ""')
dir=$(basename "$cwd")

# Resolve git branch; fall back to short SHA when detached.
# GIT_OPTIONAL_LOCKS=0 keeps git from writing lock files on a read-only query.
branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || \
         GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --short HEAD 2>/dev/null)

# ANSI colors (dim/subtle so the line stays unobtrusive)
RESET='\033[0m'
CYAN='\033[36m'
YELLOW='\033[33m'
MAGENTA='\033[35m'
DIM='\033[2m'

# Assemble: model + dir always; branch only when present
parts="${DIM}${CYAN}${model}${RESET}"
parts="${parts}  ${DIM}${YELLOW}${dir}${RESET}"

if [ -n "$branch" ]; then
  parts="${parts}  ${DIM}${MAGENTA}${branch}${RESET}"
fi

printf '%b\n' "$parts"
