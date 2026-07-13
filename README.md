# Claude Code Setup

Personal Claude Code configuration as version-controlled files, plus step-by-step instructions to reproduce the setup on a fresh machine.

Scope: personal setup only (`~/.claude`). Project-level config lives in each repo and arrives via `git clone`.

## Repo contents

| File                     | Target                            | Purpose                                                                                         |
| ------------------------ | --------------------------------- | ----------------------------------------------------------------------------------------------- |
| `setup.sh`               | —                                 | Installer: applies everything below to the profile                                              |
| `settings.json`          | `~/.claude/settings.json`         | Core settings: model, hooks, status line, plugins (deep-merged, not overwritten)                |
| `statusline-command.sh`  | `~/.claude/statusline-command.sh` | 4-line status line: identity · session usage · rate limits · cwd (details inside)               |
| `CLAUDE.md`              | `~/.claude/CLAUDE.md`             | Global memory / behavior rules                                                                  |
| `keybindings.json`       | `~/.claude/keybindings.json`      | `shift+enter` → newline                                                                         |
| `share-claude-config.sh` | —                                 | Mirror the config into a 2nd account (`~/.claude2`) via symlinks — see [SHARING.md](SHARING.md) |

All paths inside `settings.json` use `~` / `$HOME`, so the files are portable as-is — no path editing needed.

Running two accounts on one machine (personal + work)? After `setup.sh`, use [`share-claude-config.sh`](SHARING.md) to make the second profile share everything except credentials.

______________________________________________________________________

## Setup steps

### 1. Install prerequisites

```sh
# Claude Code CLI
npm install -g @anthropic-ai/claude-code   # or the native installer

# jq — required by the status line script and the mdformat hook
brew install jq

# mdformat — markdown auto-formatter used by the PostToolUse hook.
# Must end up at ~/.local/bin/mdformat (uv and pipx both install there).
uv tool install mdformat                   # or: pipx install mdformat
```

### 2. First launch & login

```sh
claude
```

Run `/login` inside the session. This creates `~/.claude/`. Exit afterwards.

### 3. Install the config files

```sh
git clone https://github.com/ensarkovankaya/claude.git && cd claude
./setup.sh
```

What `setup.sh` does (details in the script itself):

- **`settings.json` is deep-merged** into the existing file via `jq` (timestamped backup taken first) — fields not defined in the repo file, like the `SessionStart` hook that context-mode auto-adds, are preserved. Created from scratch if missing.
- `statusline-command.sh` copied + `chmod +x`; the `statusLine.command` path in settings is rewritten to point into the active profile dir. `CLAUDE.md` and `keybindings.json` copied.
- Warns if `mdformat` is missing.

It honors `CLAUDE_CONFIG_DIR`, so alternate profiles work too:

```sh
CLAUDE_CONFIG_DIR=~/.claude2 ./setup.sh
```

### 4. Plugins & marketplaces

`settings.json` already declares the marketplaces (`extraKnownMarketplaces`) and the desired plugins (`enabledPlugins`) — on the next start Claude Code fetches and enables them. Just restart:

```sh
claude
```

Then verify with `/plugin`. If anything is missing, install manually:

```
/plugin marketplace add mksglu/context-mode
/plugin marketplace add openai/codex-plugin-cc
/plugin install context7@claude-plugins-official
/plugin install skill-creator@claude-plugins-official
/plugin install frontend-design@claude-plugins-official
/plugin install gopls-lsp@claude-plugins-official
/plugin install serena@claude-plugins-official
/plugin install superpowers@claude-plugins-official
/plugin install context-mode@context-mode
/plugin install codex@openai-codex
```

| Plugin            | Marketplace             | Purpose                                                                         |
| ----------------- | ----------------------- | ------------------------------------------------------------------------------- |
| `context7`        | claude-plugins-official | Live library/framework docs lookup                                              |
| `serena`          | claude-plugins-official | LSP-based symbol-level code navigation/editing                                  |
| `superpowers`     | claude-plugins-official | Extended skill collection                                                       |
| `gopls-lsp`       | claude-plugins-official | Go language server integration                                                  |
| `skill-creator`   | claude-plugins-official | Authoring new skills                                                            |
| `frontend-design` | claude-plugins-official | Frontend/UI design assistance                                                   |
| `context-mode`    | mksglu/context-mode     | Context-window protection: sandboxed exec + FTS5 knowledge base (`ctx_*` tools) |
| `codex`           | openai/codex-plugin-cc  | OpenAI Codex integration                                                        |

### 5. Install personal skills

User-level skills live in `~/.claude/skills/` (available in every project). They are installed from their upstream sources, not synced between machines:

```sh
# Matt Pocock's skills — https://github.com/mattpocock/skills
# Pick the ones you use; make sure setup-matt-pocock-skills is selected,
# then run /setup-matt-pocock-skills once per repo inside claude
# (it scaffolds the repo's issue tracker / triage labels / docs config).
npx skills@latest add mattpocock/skills

# Playwright skills — https://github.com/microsoft/playwright-cli
npm install -g playwright-cli
playwright-cli install --skills
```

Currently installed from `mattpocock/skills` (13): `diagnose`, `grill-me`, `grill-with-docs`, `handoff`, `improve-codebase-architecture`, `prototype`, `setup-matt-pocock-skills`, `tdd`, `to-issues`, `to-prd`, `triage`, `write-a-skill`, `zoom-out`.

From `microsoft/playwright-cli` (1): `playwright-cli`.

### 6. Verify

1. [ ] Status line renders 4 lines at the bottom: identity (`model · branch · worktree · account · agent`) / session (`ctx% · cost · duration · ±lines · effort`) / account (`5h & 7d limits · PR · vim · version`) / full cwd path. Worktree, agent, and PR segments appear only when present.
2. [ ] `/plugin` shows all 8 plugins enabled
3. [ ] context-mode auto-deployed its hook: `~/.claude/hooks/context-mode-cache-heal.mjs` exists and `settings.json` gained a `SessionStart` entry
4. [ ] Ask Claude to write a test `.md` file — the mdformat hook should reformat it
5. [ ] `shift+enter` inserts a newline in the chat input

______________________________________________________________________

## What the settings do

### Key choices

| Setting                    | Value                | Why                                            |
| -------------------------- | -------------------- | ---------------------------------------------- |
| `model`                    | `claude-fable-5[1m]` | Fable 5 with 1M context as default             |
| `effortLevel`              | `xhigh`              | Max reasoning effort                           |
| `editorMode`               | `vim`                | Vim keybindings in the prompt editor           |
| `permissions.defaultMode`  | `auto`               | Auto-accept low-risk tool calls                |
| `useAutoModeDuringPlan`    | `true`               | Keep auto mode while in plan mode              |
| `verbose`                  | `true`               | Show full tool output                          |
| `language`                 | `türkçe`             | UI / responses language                        |
| `tui`                      | `fullscreen`         | Full-screen TUI layout                         |
| `autoUpdatesChannel`       | `stable`             | Track the stable release channel               |
| `worktree.baseRef`         | `fresh`              | New worktrees branch from a fresh base ref     |
| `switchModelsOnFlag`       | `false`              | Don't auto-switch models on `[1m]`-style flags |
| `remoteControlAtStartup`   | `false`              | No remote control session at launch            |
| `skipWorkflowUsageWarning` | `true`               | Suppress the workflow token-usage warning      |
| `inputNeededNotifEnabled`  | `false`              | No OS notification when input is needed        |

### Hooks

1. **PostToolUse (Write|Edit|MultiEdit) → mdformat** — declared in `settings.json`. Auto-formats any `.md`/`.markdown` file Claude writes, using `mdformat --wrap=keep --number`. Fails silently (`|| true`) so a missing binary never blocks edits.
2. **SessionStart → `context-mode-cache-heal.mjs`** — auto-deployed by the context-mode plugin on install: it places the script under `~/.claude/hooks/` and adds the `SessionStart` entry to `settings.json` itself. Intentionally not part of the repo's `settings.json` — do not hand-copy or pre-configure it.

### Global memory (`CLAUDE.md`)

Behavior rules applied in every session: extreme concision in replies and commit messages, "analyze means analyze only" (no edits/commits on analysis requests), and unresolved-questions list at the end of every plan.
