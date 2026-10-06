#!/usr/bin/env python3
"""UserPromptSubmit hook: /rename tarzı session başlığını otomatik günceller.

Başlık: <JIRA-KEY>-<açıklama-slug>
  key     : git branch'i > daha önce seçilen key > prompt'taki ilk GR-/YLC- key
  açıklama: branch'te key'den sonraki kısım > Claude'un ai-title'ı (slug)
Elle /rename yapılırsa (transcript'teki son custom-title ne bizim yazdığımız ne de şu an üreteceğimiz
başlıksa) o session'a bir daha dokunmaz. Transcript okunamazsa hiçbir şey yapmaz (fail-closed).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

# <profile>/hooks/<script> → <profile>/auto-session-title; resolve() symlink'i izler, böylece
# hooks'u paylaşan profiller (share-claude-config.sh) state'i de paylaşır — transcript'ler gibi.
STATE_DIR = Path(__file__).resolve().parent.parent / "auto-session-title"
# harness'ın prompt olarak enjekte ettiği subagent/task mesajları (source alanı bunları ayırmıyor)
INJECTED_RE = re.compile(r"<(agent-message|task-notification)\b")
KEY_RE = re.compile(r"(?<![A-Za-z0-9])(GR|YLC)-\d+(?!\d)", re.IGNORECASE)
TR = str.maketrans("çğıöşüÇĞİÖŞÜ", "cgiosucgiosu")
MAX_LEN = 60


class TranscriptError(Exception):
    pass


def slugify(text: str) -> str:
    text = text.translate(TR).lower()
    return re.sub(r"[^a-z0-9]+", "-", text).strip("-")


def last_record(transcript: str, rtype: str, field: str) -> str | None:
    """Son <rtype> kaydının <field> değeri; kayıt yoksa None, okunamazsa TranscriptError."""
    try:
        proc = subprocess.run(
            ["grep", "-F", f'"type":"{rtype}"', transcript],
            capture_output=True, text=True, timeout=3,
        )
    except Exception as e:
        raise TranscriptError(e) from e
    if proc.returncode > 1:
        raise TranscriptError(proc.stderr)
    for line in reversed(proc.stdout.splitlines()):
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if rec.get("type") == rtype and isinstance(rec.get(field), str):
            return rec[field]
    return None


def git_branch(cwd: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", cwd, "branch", "--show-current"],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
    except Exception:
        return ""


def load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def save_state(path: Path, state: dict) -> None:
    tmp = path.with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(state))
    os.replace(tmp, path)


def build_title(data: dict, state: dict, transcript: str) -> tuple[str | None, str]:
    branch = git_branch(data.get("cwd") or os.getcwd())
    key, desc = None, None
    if m := KEY_RE.search(branch):
        key = m.group(0).upper()
        desc = slugify(branch[m.end():]) or None
    elif state.get("key"):
        key = state["key"]
    elif m := KEY_RE.search(data.get("prompt", "")):
        key = m.group(0).upper()

    if not desc and transcript:
        ai = last_record(transcript, "ai-title", "aiTitle")
        if ai:
            desc = slugify(KEY_RE.sub("", ai)) or None

    title = "-".join(p for p in (key, desc) if p)[:MAX_LEN].rstrip("-")
    return key, title


def main() -> None:
    if os.environ.get("AUTO_SESSION_TITLE_DISABLE"):
        return
    data = json.load(sys.stdin)
    if data.get("source", "user") != "user" or INJECTED_RE.search(data.get("prompt", "")):
        return
    sid = data.get("session_id")
    transcript = data.get("transcript_path") or ""
    if not sid:
        return
    if transcript and not os.path.exists(transcript):
        transcript = ""

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state_file = STATE_DIR / f"{sid}.json"
    state = load_state(state_file)
    if state.get("locked"):
        return

    try:
        current = last_record(transcript, "custom-title", "customTitle") if transcript else None
        if current and "key" not in state and (m := KEY_RE.search(current)):
            state["key"] = m.group(0).upper()  # resume/fork: state'siz devralınan başlık
        key, title = build_title(data, state, transcript)
    except TranscriptError:
        return

    if current and current not in (state.get("last_set"), title):
        state["locked"] = True
        save_state(state_file, state)
        return
    if not title or title == state.get("last_set"):
        return

    state.update(key=key, last_set=title)
    save_state(state_file, state)
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "sessionTitle": title,
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
