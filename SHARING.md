# Sharing config across accounts (`share-claude-config.sh`)

Run two Claude Code accounts on one machine (e.g. personal + work) without maintaining two copies of the config. `setup.sh` installs this repo into **one** profile; this script then makes a **second** profile mirror it via symlinks, so both accounts share the same skills, agents, hooks, settings, sessions, and memory — while keeping their logins separate.

```
repo ──setup.sh──► ~/.claude (canonical) ──share-claude-config.sh──► ~/.claude2 (symlinks)
```

The two accounts differ **only** in their credentials and `.claude.json`. Everything else is one shared source of truth.

______________________________________________________________________

## Usage

```sh
# preview — prints every action, changes nothing
./share-claude-config.sh --dry-run

# apply — default SOURCE=~/.claude TARGET=~/.claude2
./share-claude-config.sh

# custom dirs (positional): SOURCE then TARGET
./share-claude-config.sh ~/.claude ~/.work-claude
```

Point the second account at its dir with the `CLAUDE_CONFIG_DIR` env var:

```sh
CLAUDE_CONFIG_DIR=~/.claude2 claude
```

______________________________________________________________________

## What it shares

`SOURCE` (`~/.claude`) stays canonical; each item below becomes a symlink in `TARGET` (`~/.claude2`) pointing back at the source:

| Item                                   | Why it's shared                                            |
| -------------------------------------- | ---------------------------------------------------------- |
| `projects`                             | sessions + persistent memory                               |
| `CLAUDE.md`                            | global instructions                                        |
| `settings.json`, `settings.local.json` | hooks, permissions, env, model                             |
| `skills`, `agents`, `hooks`, `plugins` | installed capabilities                                     |
| `plans`, `tasks`                       | in-flight work                                             |
| `file-history`                         | rewind/checkpoint — must follow the sessions it references |
| `history.jsonl`                        | command history                                            |
| `keybindings.json`                     | key bindings                                               |
| `statusline-command.sh`                | status line script                                         |

## What it never touches (per-account, by design)

`.claude.json`, credentials / OS keychain, cache, statsig, telemetry. These must stay distinct per account — sharing them would cross the two logins.

> Because `settings.json` is shared and its `statusLine.command` is an absolute path (`~/.claude/statusline-command.sh`), both accounts run the same status line script. The script resolves the active account's email from the right `.claude.json` using `CLAUDE_CONFIG_DIR`, so each account still shows its own identity.

______________________________________________________________________

## How it works

1. **Arg parsing.** Optional leading `--dry-run` sets a flag; remaining positionals override `SOURCE` / `TARGET` (defaults `~/.claude` → `~/.claude2`).
2. **Guards.** Both dirs must exist, and `SOURCE` must not resolve to the same path as `TARGET` (compared via `cd && pwd`) — otherwise it aborts before touching anything.
3. **Per-item loop** over `SHARED_ITEMS`, each item handled idempotently:
   - **No source** (`$SOURCE/$item` missing) → `skip`, nothing to link.
   - **Already the correct symlink** (`readlink` points at the source) → `skip`, so re-runs are safe.
   - **A real file/dir or a stale symlink is in the way** → it's **moved** (never deleted) into a timestamped `TARGET/.share-backup-<ts>/` first, then the correct symlink is created.
4. **`--dry-run`** routes every mutating command (`mkdir`, `mv`, `ln`) through a `run()` wrapper that just echoes `[dry-run] …` instead of executing — so you can preview the full plan with zero side effects.
5. **Summary.** Prints counts (`linked / backed up / skipped`), the backup dir path if anything was moved, and the explicit list of what stays per-account.

### Safety properties

- **Non-destructive** — anything in the way is backed up, never removed.
- **Idempotent** — correct symlinks are detected and skipped; safe to run repeatedly (e.g. after each `setup.sh`).
- **`set -euo pipefail`** — aborts on the first error rather than half-linking.

______________________________________________________________________

## Typical workflow

```sh
./setup.sh                    # 1. install repo → ~/.claude
./share-claude-config.sh      # 2. mirror ~/.claude → ~/.claude2 via symlinks
CLAUDE_CONFIG_DIR=~/.claude2 claude   # 3. run the second account
```

Re-run both after pulling repo updates: `setup.sh` refreshes `~/.claude`, and because `~/.claude2` symlinks straight back at it, the second account picks the changes up with no extra step (re-run the share script only when a **new** shared item appears).
