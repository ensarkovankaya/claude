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
#   On every refresh, Claude Code pipes a JSON payload to this script's
#   stdin. The script prints up to FOUR lines, each answering one question
#   (segments shown only when present):
#     line 1  identity:  @account · ◆model ▲effort gauge · ⎇branch
#                        · ⌂worktree · ⚙agent
#     line 2  session:   ctx bar (+⚠200k) · $cost · ◷duration · ±lines
#                        · ✻think · »fast
#     line 3  quota:     5h & 7d bars with pace marker ┃ and ↻reset clocks
#     line 4  location:  ▸cwd · vim mode · version · ✎(non-default) style
#   Bars are 10 cells with 1/8 sub-cell blocks, colored by threshold:
#   green < 50, yellow < 80, red >= 80. The pace marker ┃ sits where the
#   elapsed share of the limit window falls: fill past it means the limit
#   runs out before it resets at this pace.
#
# REQUIRES: jq; runs on macOS /bin/bash 3.2

# Read the full JSON payload Claude Code sends on stdin
input=$(cat)

# Pull every field we care about in a single jq pass, joined with the 0x1f
# unit separator so the model name's spaces survive and empty columns are
# kept. Rate-limit percents stay empty when the payload has none.
IFS=$'\x1f' read -r model cwd ctx_pct cost lines_add lines_rem effort \
    think fast five_pct seven_pct five_reset seven_reset out_style version vim_mode exceeds \
    duration_ms worktree agent \
    < <(echo "$input" | jq -r 'def pct: if . == null then "" else round end; [
        .model.display_name             // "Claude",
        .cwd                            // "",
        ((.context_window.used_percentage // 0) | round),
        (.cost.total_cost_usd           // 0),
        (.cost.total_lines_added        // 0),
        (.cost.total_lines_removed      // 0),
        (.effort.level                  // ""),
        (.thinking.enabled              // false),
        (.fast_mode                     // false),
        (.rate_limits.five_hour.used_percentage | pct),
        (.rate_limits.seven_day.used_percentage | pct),
        ((.rate_limits.five_hour.resets_at // 0) | floor),
        ((.rate_limits.seven_day.resets_at // 0) | floor),
        (.output_style.name             // ""),
        (.version                       // ""),
        (.vim.mode                      // ""),
        (.exceeds_200k_tokens           // false),
        ((.cost.total_duration_ms       // 0) | floor),
        (.workspace.git_worktree        // .worktree.name // ""),
        (.agent.name                    // "")
      ] | map(tostring) | join("\u001f")' 2>/dev/null)

# Defaults for an empty/invalid payload so the arithmetic below never errors
model=${model:-Claude} ctx_pct=${ctx_pct:-0} cost=${cost:-0}
lines_add=${lines_add:-0} lines_rem=${lines_rem:-0}
five_reset=${five_reset:-0} seven_reset=${seven_reset:-0} duration_ms=${duration_ms:-0}

# Home prefix shown as ~ (built by hand: a ~ in ${var/#…/~} gets tilde-expanded)
dir="$cwd"
case "$cwd" in "$HOME"|"$HOME"/*) dir="~${cwd#"$HOME"}" ;; esac

# Resolve account email from the active config dir's .claude.json.
# Default account keeps it at ~/.claude.json; CLAUDE_CONFIG_DIR accounts inside the dir.
cfg_dir="${CLAUDE_CONFIG_DIR/#\~/$HOME}"
acct_file="${cfg_dir:+$cfg_dir/.claude.json}"
acct_file="${acct_file:-$HOME/.claude.json}"
acct=$(jq -r '.oauthAccount.emailAddress // empty' "$acct_file" 2>/dev/null | cut -d@ -f1)

# Resolve git branch; fall back to short SHA when detached.
# GIT_OPTIONAL_LOCKS=0 keeps git from writing lock files on a read-only query.
branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || \
         GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --short HEAD 2>/dev/null)

# ANSI colors. Text segments stay dim; bars are full intensity so they read
# at a glance. Real escape bytes, so lines are printed with %s and
# backslashes in data (cwd, branch) stay literal.
RESET=$'\033[0m'
CYAN=$'\033[36m'
YELLOW=$'\033[33m'
MAGENTA=$'\033[35m'
GREEN=$'\033[32m'
RED=$'\033[31m'
BLUE=$'\033[34m'
GRAY=$'\033[90m'
# Pace marker: 256-color 136 (#af8700), dark yellow
PACE=$'\033[38;5;136m'
# Bars' green: 256-color 28 (#008700), darker than the theme's green
BAR_GREEN=$'\033[38;5;28m'
DIM=$'\033[2m'

SEP="${DIM}${GRAY}│${RESET}"
BAR_CELLS=10
# Index n = n/8 of a cell filled from the left
PARTS=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
EFFORT_LEVELS="low medium high xhigh max"

# Pick a color for a percentage: green < 50, yellow < 80, else red.
pct_color() {
  local p=$1
  if   [ "$p" -ge 80 ]; then printf '%s' "$RED"
  elif [ "$p" -ge 50 ]; then printf '%s' "$YELLOW"
  else                       printf '%s' "$GREEN"
  fi
}

# Dim gray symbol/label ($1) followed by a space.
sym() { printf '%s' "${DIM}${GRAY}$1${RESET} "; }

# 10-cell bar for percent $1; optional $2 = cell index of the pace marker.
# Sub-cell precision: 80 eighths across the bar, so 1 eighth = 1.25%.
bar() {
  local p=$1 mark=${2:-} color eighths full rem i out=""
  [ "$p" -gt 100 ] && p=100
  [ "$p" -lt 0 ] && p=0
  color=$(pct_color "$p")
  [ "$color" = "$GREEN" ] && color=$BAR_GREEN
  eighths=$(( (p * BAR_CELLS * 8 + 50) / 100 ))
  full=$(( eighths / 8 )) rem=$(( eighths % 8 ))
  for (( i = 0; i < BAR_CELLS; i++ )); do
    if [ "$i" = "$mark" ]; then
      out="${out}${PACE}┃${RESET}"
    elif [ "$i" -lt "$full" ]; then
      out="${out}${color}█${RESET}"
    elif [ "$i" -eq "$full" ] && [ "$rem" -gt 0 ]; then
      out="${out}${color}${PARTS[$rem]}${RESET}"
    else
      out="${out}${DIM}${GRAY}░${RESET}"
    fi
  done
  printf '%s' "$out"
}

# Cell index where the elapsed share of a limit window falls, from its reset
# epoch ($1) and window length in seconds ($2). Emits nothing without a reset.
pace_cell() {
  [ "$1" = "0" ] && return
  local left=$(( $1 - now )) cell
  [ "$left" -lt 0 ] && left=0
  [ "$left" -gt "$2" ] && left=$2
  cell=$(( ($2 - left) * BAR_CELLS / $2 ))
  [ "$cell" -ge "$BAR_CELLS" ] && cell=$(( BAR_CELLS - 1 ))
  printf '%s' "$cell"
}

# 5-step ▰▱ gauge for an effort level ($1). Emits nothing for an unknown level.
effort_gauge() {
  local lvl n=0 i=0 out=""
  for lvl in $EFFORT_LEVELS; do
    i=$(( i + 1 ))
    [ "$lvl" = "$1" ] && n=$i
  done
  [ "$n" -eq 0 ] && return
  for (( i = 1; i <= 5; i++ )); do
    if [ "$i" -le "$n" ]; then out="${out}${BLUE}▰${RESET}"
    else                       out="${out}${DIM}${GRAY}▱${RESET}"
    fi
  done
  printf '%s' "$out"
}

# Render a "↻<clock>" reset segment from an epoch ($1) using date format $2.
# Emits nothing when the epoch is absent (0) or date(1) fails.
# BSD date takes -r <epoch>; GNU date needs -d @<epoch>.
fmt_reset() {
  [ "$1" = "0" ] && return
  local clk
  clk=$(date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2" 2>/dev/null) || return
  [ -n "$clk" ] && printf '%s' " ${DIM}${GRAY}↻${clk}${RESET}"
}

# Human-readable session duration from milliseconds ($1). Emits nothing at 0.
fmt_dur() {
  local s=$(( ${1:-0} / 1000 ))
  [ "$s" -le 0 ] && return
  if   [ "$s" -ge 3600 ]; then printf '%dh%dm' "$((s/3600))" "$(((s%3600)/60))"
  elif [ "$s" -ge 60 ];   then printf '%dm' "$((s/60))"
  else                         printf '%ds' "$s"
  fi
}

# Append segment $2 to the line variable named $1, joined by the separator.
add() { eval "$1=\"\${$1:+\$$1  \$SEP  }\$2\""; }

now=$(date +%s)

# ── Line 1: identity — who & where ───────────────────────────────────
line1=""
[ -n "$acct" ]     && add line1 "${DIM}${GREEN}@${acct}${RESET}"
seg="$(sym ◆)${DIM}${CYAN}${model}${RESET}"
# Effort gauge right after the model it applies to
if [ -n "$effort" ]; then
  gauge=$(effort_gauge "$effort")
  seg="${seg}  $(sym ▲)${gauge:+$gauge }${DIM}${BLUE}${effort}${RESET}"
fi
add line1 "$seg"
[ -n "$branch" ]   && add line1 "$(sym ⎇)${DIM}${MAGENTA}${branch}${RESET}"
[ -n "$worktree" ] && add line1 "$(sym ⌂)${DIM}${BLUE}${worktree}${RESET}"
[ -n "$agent" ]    && add line1 "$(sym ⚙)${DIM}${MAGENTA}${agent}${RESET}"

# ── Line 2: this session — usage + reasoning mode ────────────────────
# Context window bar (+ 200k warning badge when exceeded)
seg="$(sym ctx)$(bar "$ctx_pct") ${DIM}$(pct_color "$ctx_pct")${ctx_pct}%${RESET}"
[ "$exceeds" = "true" ] && seg="${seg} ${DIM}${RED}⚠200k${RESET}"
line2=""
add line2 "$seg"

# Session cost (2 decimals)
cost_fmt=$(export LC_ALL=C; printf '%.2f' "$cost" 2>/dev/null) || cost_fmt="0.00"
add line2 "${DIM}${GREEN}\$${cost_fmt}${RESET}"

# Session wall-clock duration
dur=$(fmt_dur "$duration_ms")
[ -n "$dur" ] && add line2 "$(sym ◷)${DIM}${BLUE}${dur}${RESET}"

# Lines changed this session (skip when nothing touched)
if [ "$lines_add" != "0" ] || [ "$lines_rem" != "0" ]; then
  add line2 "$(sym ±)${DIM}${GREEN}+${lines_add}${RESET} ${DIM}${RED}-${lines_rem}${RESET}"
fi

# Thinking/fast flags
flags=""
[ "$think" = "true" ] && flags="${flags:+$flags  }$(sym ✻)${DIM}${MAGENTA}think${RESET}"
[ "$fast" = "true" ]  && flags="${flags:+$flags  }$(sym »)${DIM}${YELLOW}fast${RESET}"
[ -n "$flags" ]       && add line2 "$flags"

# ── Line 3: account quota — 5-hour & 7-day rate limits ───────────────
# Omitted when the payload has none (API-key auth, or before the first
# response). 5h resets within the day → time only; 7d → date + time.
line3=""
[ -n "$five_pct" ] && add line3 "$(sym 5h)$(bar "$five_pct" "$(pace_cell "$five_reset" 18000)") ${DIM}$(pct_color "$five_pct")${five_pct}%${RESET}$(fmt_reset "$five_reset" '%H:%M')"
[ -n "$seven_pct" ] && add line3 "$(sym 7d)$(bar "$seven_pct" "$(pace_cell "$seven_reset" 604800)") ${DIM}$(pct_color "$seven_pct")${seven_pct}%${RESET}$(fmt_reset "$seven_reset" '%m-%d %H:%M')"

# ── Line 4: location + client state ──────────────────────────────────
line4=""
[ -n "$dir" ]      && add line4 "$(sym ▸)${DIM}${YELLOW}${dir}${RESET}"
[ -n "$vim_mode" ] && add line4 "$(sym vim)${DIM}${GRAY}${vim_mode}${RESET}"
[ -n "$version" ]  && add line4 "${DIM}${GRAY}v${version}${RESET}"
[ -n "$out_style" ] && [ "$out_style" != "default" ] && add line4 "$(sym ✎)${DIM}${GRAY}${out_style}${RESET}"

for line in "$line1" "$line2" "$line3" "$line4"; do
  if [ -n "$line" ]; then printf '%s\n' "$line"; fi
done
