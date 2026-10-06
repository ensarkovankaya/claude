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
#   stdin. The script prints FOUR grouped lines, each answering one
#   question (segments shown only when present; metric lines use dim bars):
#     line 1  identity:  model · git branch · worktree · account · agent
#     line 2  session:   context% (+200k warn) · cost · duration
#                        · +added/-removed · effort · think/fast flags
#     line 3  account:   5h & 7d rate limits (+reset clocks) · PR (state)
#                        · vim mode · version · (non-default) output style
#     line 4  location:  full cwd path
#   Percent segments (context, rate limits) are colored by threshold:
#   green < 50, yellow < 80, red >= 80. The branch segment is omitted
#   outside a git repo; on a detached HEAD it falls back to the short SHA.
#
# REQUIRES: jq

# Read the full JSON payload Claude Code sends on stdin
input=$(cat)

# Pull every field we care about in a single jq pass, joined with the 0x1f
# unit separator so the model name's spaces survive and empty columns are
# kept. Rate-limit percents stay empty when the payload has none.
IFS=$'\x1f' read -r model cwd ctx_pct cost lines_add lines_rem effort \
    think fast five_pct seven_pct five_reset seven_reset out_style version vim_mode exceeds \
    duration_ms worktree agent pr_num pr_state \
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
        (.agent.name                    // ""),
        (.pr.number                     // ""),
        (.pr.review_state               // "")
      ] | map(tostring) | join("")' 2>/dev/null)

# Defaults for an empty/invalid payload so the arithmetic below never errors
model=${model:-Claude} ctx_pct=${ctx_pct:-0} cost=${cost:-0}
lines_add=${lines_add:-0} lines_rem=${lines_rem:-0}
five_reset=${five_reset:-0} seven_reset=${seven_reset:-0} duration_ms=${duration_ms:-0}

dir="$cwd"

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

# ANSI colors (dim/subtle so the line stays unobtrusive). Real escape bytes,
# so lines are printed with %s and backslashes in data (cwd, branch) stay literal.
RESET=$'\033[0m'
CYAN=$'\033[36m'
YELLOW=$'\033[33m'
MAGENTA=$'\033[35m'
GREEN=$'\033[32m'
RED=$'\033[31m'
BLUE=$'\033[34m'
GRAY=$'\033[90m'
DIM=$'\033[2m'

SEP="${DIM}${GRAY}│${RESET}"

# Pick a color for a percentage: green < 50, yellow < 80, else red.
pct_color() {
  local p=$1
  if   [ "$p" -ge 80 ]; then printf '%s' "$RED"
  elif [ "$p" -ge 50 ]; then printf '%s' "$YELLOW"
  else                       printf '%s' "$GREEN"
  fi
}

# Render a "→<clock>" reset segment from an epoch ($1) using date format $2.
# Emits nothing when the epoch is absent (0) or date(1) fails.
# BSD date takes -r <epoch>; GNU date needs -d @<epoch>.
fmt_reset() {
  [ "$1" = "0" ] && return
  local clk
  clk=$(date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2" 2>/dev/null) || return
  [ -n "$clk" ] && printf '%s' "${DIM}${GRAY}→${clk}${RESET}"
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

# ── Line 1: identity — who & where (space-separated, no bars) ────────
line1="${DIM}${CYAN}${model}${RESET}"
[ -n "$branch" ]   && line1="${line1}  ${DIM}${MAGENTA}${branch}${RESET}"
[ -n "$worktree" ] && line1="${line1}  ${DIM}${BLUE}wt:${worktree}${RESET}"
[ -n "$acct" ]     && line1="${line1}  ${DIM}${GREEN}${acct}${RESET}"
[ -n "$agent" ]    && line1="${line1}  ${DIM}${MAGENTA}⚙${agent}${RESET}"

# ── Line 2: this session — usage + reasoning mode ────────────────────
# Context window usage (+ 200k warning badge when exceeded)
c=$(pct_color "$ctx_pct")
line2="${DIM}${c}ctx ${ctx_pct}%${RESET}"
[ "$exceeds" = "true" ] && line2="${line2} ${DIM}${RED}⚠200k+${RESET}"

# Session cost (2 decimals)
cost_fmt=$(LC_ALL=C printf '%.2f' "$cost" 2>/dev/null) || cost_fmt="0.00"
line2="${line2}  ${SEP}  ${DIM}${GREEN}\$${cost_fmt}${RESET}"

# Session wall-clock duration
dur=$(fmt_dur "$duration_ms")
[ -n "$dur" ] && line2="${line2}  ${SEP}  ${DIM}${BLUE}${dur}${RESET}"

# Lines changed this session (skip when nothing touched)
if [ "$lines_add" != "0" ] || [ "$lines_rem" != "0" ]; then
  line2="${line2}  ${SEP}  ${DIM}${GREEN}+${lines_add}${RESET}${DIM}/${RED}-${lines_rem}${RESET}"
fi

# Effort + thinking/fast flags
flags=""
[ -n "$effort" ]       && flags="${DIM}${BLUE}${effort}${RESET}"
[ "$think" = "true" ]  && flags="${flags:+$flags }${DIM}${MAGENTA}think${RESET}"
[ "$fast" = "true" ]   && flags="${flags:+$flags }${DIM}${YELLOW}fast${RESET}"
[ -n "$flags" ]        && line2="${line2}  ${SEP}  ${flags}"

# ── Line 3: account quota + client/editor state ──────────────────────
# Rate limits (5-hour & 7-day), each with its reset clock; omitted when the
# payload has none (API-key auth, or before the first response).
# 5h resets within the day → time only; 7d can be days out → date + time.
line3=""
add3() { line3="${line3:+$line3  $SEP  }$1"; }
[ -n "$five_pct" ]  && add3 "${DIM}$(pct_color "$five_pct")5h ${five_pct}%${RESET}$(fmt_reset "$five_reset" '%H:%M')"
[ -n "$seven_pct" ] && add3 "${DIM}$(pct_color "$seven_pct")7d ${seven_pct}%${RESET}$(fmt_reset "$seven_reset" '%m-%d %H:%M')"

# Active PR (number + review state); state color: approved=green,
# changes_requested=red, otherwise yellow.
if [ -n "$pr_num" ]; then
  case "$pr_state" in
    approved)          ps=$GREEN ;;
    changes_requested) ps=$RED ;;
    *)                 ps=$YELLOW ;;
  esac
  pr_seg="${DIM}${CYAN}PR#${pr_num}${RESET}"
  [ -n "$pr_state" ] && pr_seg="${pr_seg} ${DIM}${ps}${pr_state}${RESET}"
  add3 "$pr_seg"
fi

# Vim mode · version · (non-default) output style
[ -n "$vim_mode" ]                                   && add3 "${DIM}${GRAY}${vim_mode}${RESET}"
[ -n "$version" ]                                    && add3 "${DIM}${GRAY}v${version}${RESET}"
[ -n "$out_style" ] && [ "$out_style" != "default" ] && add3 "${DIM}${GRAY}${out_style}${RESET}"

# ── Line 4: full working directory path ──────────────────────────────
line4="${DIM}${YELLOW}${dir}${RESET}"

printf '%s\n%s\n%s\n%s\n' "$line1" "$line2" "$line3" "$line4"
