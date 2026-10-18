# Claude Code Setup

Personal Claude Code configuration as version-controlled files, plus step-by-step instructions to reproduce the setup on a fresh machine.

Scope: personal setup only (`~/.claude`). Project-level config lives in each repo and arrives via `git clone`.

## Repo contents

| File                          | Target                                  | Purpose                                                                                              |
| ----------------------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `setup.sh`                    | —                                       | Installer: applies everything below to the profile                                                   |
| `settings.json`               | `~/.claude/settings.json`               | Core settings: model, hooks, status line, plugins (deep-merged, not overwritten)                     |
| `statusline-command.sh`       | `~/.claude/statusline-command.sh`       | 4-line status line: identity · session usage · quota bars w/ pace marker · location (details inside) |
| `hooks/auto-session-title.py` | `~/.claude/hooks/auto-session-title.py` | `UserPromptSubmit` hook: auto `/rename`-style session title (`GR-1234-short-desc`)                   |
| `CLAUDE.md`                   | `~/.claude/CLAUDE.md`                   | Global memory / behavior rules                                                                       |
| `keybindings.json`            | `~/.claude/keybindings.json`            | `shift+enter` → newline                                                                              |
| `share-claude-config.sh`      | —                                       | Mirror the config into a 2nd account (`~/.claude2`) via symlinks — see [SHARING.md](SHARING.md)      |

All paths inside `settings.json` use `~` / `$HOME`, so the files are portable as-is — no path editing needed.

Running two accounts on one machine (personal + work)? After `setup.sh`, use [`share-claude-config.sh`](SHARING.md) to make the second profile share everything except credentials.

______________________________________________________________________

## Setup steps

### 1. Install prerequisites

```sh
# Claude Code CLI
npm install -g @anthropic-ai/claude-code   # or the native installer

# jq — required by setup.sh (aborts without it), the status line and the mdformat hook
brew install jq

# mdformat — markdown auto-formatter used by the PostToolUse hook.
# Must end up at ~/.local/bin/mdformat (uv and pipx both install there).
uv tool install mdformat                   # or: pipx install mdformat

# python3 >= 3.8 — runs the auto session title hook (macOS system python 3.9 is fine)
brew install python
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

- **`settings.json` is deep-merged** into the existing file via `jq` (backup taken first, newest 5 kept) — fields not defined in the repo file, like the `SessionStart` hook that context-mode auto-adds, are preserved. Created from scratch if missing; aborts if the existing file is not a JSON object.
  - Repo scalar values (e.g. `effortLevel`, `model`) win, so a re-run resets changes made via `/config` / `/model`. Arrays (e.g. `autoMode.soft_deny`) are replaced, not appended; object keys not in the repo (e.g. a local `autoMode.environment`) are kept.
  - Hook lists are merged per event: a repo hook replaces an existing entry with the same command (`$HOME`/`~` normalized), other hooks in that event are kept.
- `statusline-command.sh` and `hooks/auto-session-title.py` copied + `chmod +x`; the `statusLine.command` and hook script paths in settings are rewritten to point into the active profile dir. `CLAUDE.md` and `keybindings.json` copied.
- Warns if `mdformat` or `python3 >= 3.8` is missing.

It honors `CLAUDE_CONFIG_DIR`, so alternate profiles work too:

```sh
CLAUDE_CONFIG_DIR=~/.work-claude ./setup.sh
```

A profile mirrored by [`share-claude-config.sh`](SHARING.md) is refused (its files are symlinks into the source profile) — run `setup.sh` against the source profile instead.

### 4. Plugins & marketplaces

`settings.json` already declares the marketplaces (`extraKnownMarketplaces`) and the desired plugins (`enabledPlugins`) — on the next start Claude Code fetches and enables them. Just restart:

```sh
claude
```

Then verify with `/plugin`. If anything is missing, install manually:

```
/plugin marketplace add mksglu/context-mode
/plugin marketplace add openai/codex-plugin-cc
/plugin marketplace add kepano/obsidian-skills
/plugin install context7@claude-plugins-official
/plugin install skill-creator@claude-plugins-official
/plugin install frontend-design@claude-plugins-official
/plugin install gopls-lsp@claude-plugins-official
/plugin install postman@claude-plugins-official
/plugin install superpowers@claude-plugins-official
/plugin install context-mode@context-mode
/plugin install codex@openai-codex
/plugin install obsidian@obsidian-skills
```

| Plugin            | Marketplace (repo)                         | Purpose                                                                         |
| ----------------- | ------------------------------------------ | ------------------------------------------------------------------------------- |
| `context7`        | `claude-plugins-official`                  | Live library/framework docs lookup                                              |
| `postman`         | `claude-plugins-official`                  | Postman CLI/MCP: API mocking, testing, monitoring, docs                         |
| `superpowers`     | `claude-plugins-official`                  | Extended skill collection                                                       |
| `gopls-lsp`       | `claude-plugins-official`                  | Go language server integration                                                  |
| `skill-creator`   | `claude-plugins-official`                  | Authoring new skills                                                            |
| `frontend-design` | `claude-plugins-official`                  | Frontend/UI design assistance                                                   |
| `context-mode`    | `context-mode` (mksglu/context-mode)       | Context-window protection: sandboxed exec + FTS5 knowledge base (`ctx_*` tools) |
| `codex`           | `openai-codex` (openai/codex-plugin-cc)    | OpenAI Codex integration                                                        |
| `obsidian`        | `obsidian-skills` (kepano/obsidian-skills) | Obsidian vault skills: CLI, markdown, Bases, Canvas                             |

### 5. Optional skills

Not part of this setup; enable where needed:

- **Extra marketplaces** — declared in `extraKnownMarketplaces` but no plugin enabled; pick from `/plugin` per project (e.g. `enabledPlugins` in the repo's `.claude/settings.local.json`) or globally:

  | Marketplace           | Repo                                                                                            |
  | --------------------- | ----------------------------------------------------------------------------------------------- |
  | `mattpocock`          | [mattpocock/skills](https://github.com/mattpocock/skills)                                       |
  | `devfast`             | [devdotfast/whiteboard](https://github.com/devdotfast/whiteboard)                               |
  | `ui-ux-pro-max-skill` | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) |
  | `understand-anything` | [Egonex-AI/Understand-Anything](https://github.com/Egonex-AI/Understand-Anything)               |

- **Playwright CLI + its skills** ([microsoft/playwright-cli](https://github.com/microsoft/playwright-cli)):

  ```sh
  npm install -g @playwright/cli@latest
  playwright-cli install --skills
  ```

### 6. Verify

1. [ ] Status line renders up to 4 lines at the bottom: identity (`@account · ◆model ▲effort · ⎇branch · ⌂worktree · ⚙agent`) / session (`ctx bar · ⚠200k · $cost · ◷duration · ±lines · ✻think · »fast`) / quota (`5h & 7d bars w/ ┃ pace marker · ↻reset`) / location (`▸~/cwd · vim · version · ✎style`). Segments appear only when present.
2. [ ] `/plugin` shows all 9 plugins enabled
3. [ ] context-mode auto-deployed its hook: `~/.claude/hooks/context-mode-cache-heal.mjs` exists and `settings.json` gained a `SessionStart` entry
4. [ ] Ask Claude to write a test `.md` file — the mdformat hook should reformat it
5. [ ] `shift+enter` inserts a newline in the chat input
6. [ ] Send a prompt mentioning `GR-1234` — the session title becomes `GR-1234`, then gains a short description from the next prompt on

______________________________________________________________________

## What the settings do

### Key choices

| Setting                             | Value                              | Why                                                                                    |
| ----------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------- |
| `model`                             | `opus`                             | Default model alias                                                                    |
| `effortLevel`                       | `high`                             | Default reasoning effort                                                               |
| `modelSettings`                     | per model                          | Effort per model: `claude-opus-5` → `xhigh`, `claude-opus-5-5` → `high`                |
| `minimumVersion`                    | `2.1.183`                          | Refuse to run older Claude Code builds                                                 |
| `editorMode`                        | `vim`                              | Vim keybindings in the prompt editor                                                   |
| `permissions.defaultMode`           | `auto`                             | Auto-accept low-risk tool calls                                                        |
| `useAutoModeDuringPlan`             | `true`                             | Keep auto mode while in plan mode                                                      |
| `skipAutoPermissionPrompt`          | `true`                             | No confirmation prompt when entering auto mode                                         |
| `skipDangerousModePermissionPrompt` | `true`                             | No confirmation prompt when entering bypass-permissions mode                           |
| `verbose`                           | `false`                            | Compact tool output                                                                    |
| `language`                          | `türkçe`                           | UI / responses language                                                                |
| `tui`                               | `fullscreen`                       | Full-screen TUI layout                                                                 |
| `statusLine.padding`                | `0`                                | Status line flush with the edge                                                        |
| `autoUpdatesChannel`                | `latest`                           | Track the latest release channel                                                       |
| `timeFormat`                        | `24-hour`                          | 24-hour clock in the UI                                                                |
| `enableArtifact`                    | `false`                            | Artifacts disabled                                                                     |
| `autoMode.soft_deny`                | `$defaults` + `Bash(psql:* prod*)` | Built-in soft-deny rules plus a block on `psql` against prod targets                   |
| `worktree.baseRef`                  | `fresh`                            | New worktrees branch from the remote default branch (the default; `head` = local HEAD) |
| `switchModelsOnFlag`                | `false`                            | Don't auto-switch models on `[1m]`-style flags                                         |
| `remoteControlAtStartup`            | `false`                            | No remote control session at launch                                                    |
| `skipWorkflowUsageWarning`          | `true`                             | Suppress the workflow token-usage warning                                              |
| `inputNeededNotifEnabled`           | `false`                            | No OS notification when input is needed                                                |
| `agentPushNotifEnabled`             | `false`                            | No push notification from agents                                                       |

### Hooks

1. **PostToolUse (Write|Edit|MultiEdit) → mdformat** — declared in `settings.json`. Auto-formats any `.md`/`.markdown` file Claude writes, using `mdformat --wrap=keep --number`, except files under `~/Obsedian/` (Obsidian vaults keep their own formatting). Fails silently (`|| true`) so a missing binary never blocks edits.
2. **UserPromptSubmit → `auto-session-title.py`** — declared in `settings.json`. Sets a `/rename`-style title via `hookSpecificOutput.sessionTitle` on every user prompt, only when it changes:
   - **Jira key:** current git branch of the cwd (`feat/GR-1234-add-filter`) > the key picked earlier in the session > first `GR-`/`YLC-` key in the prompt. A key merely mentioned later doesn't retitle the session.
   - **Description:** branch part after the key > Claude's own `ai-title` from the transcript, slugified (no extra model call; it exists from the 2nd prompt on).
   - **Manual `/rename` wins:** if the transcript's last `custom-title` is neither what the hook last set nor what it would set now, that session is locked and never touched again. If the transcript can't be read, the hook does nothing (fail-closed).
   - Skips non-user prompts (`-p`, SDK, loops) and harness-injected subagent/task messages (`<agent-message`, `<task-notification>`). State: `<profile>/auto-session-title/<session_id>.json`, next to the installed script with symlinks resolved — so a profile mirrored by `share-claude-config.sh` uses the source profile's state (delete the file to unlock). Disable with `AUTO_SESSION_TITLE_DISABLE=1`. Needs python3 >= 3.8; errors are swallowed.
3. **SessionStart → `context-mode-cache-heal.mjs`** — auto-deployed by the context-mode plugin on install: it places the script under `~/.claude/hooks/` and adds the `SessionStart` entry to `settings.json` itself. Intentionally not part of the repo's `settings.json` — do not hand-copy or pre-configure it.

### Global memory (`CLAUDE.md`)

Behavior rules applied in every session: extreme concision in replies and commit messages, "analyze means analyze only" (no edits/commits on analysis requests), and unresolved-questions list at the end of every plan.
