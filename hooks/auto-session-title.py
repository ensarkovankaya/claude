#!/usr/bin/env python3
"""UserPromptSubmit hook: /rename tarzı session başlığını otomatik günceller.

Başlık: <JIRA-KEY>-<açıklama-slug>
  key   : worktree branch'i > prompt'taki ilk GR-/YLC- key > önceki key
  açıklama: branch'te key'den sonraki kısım > Claude'un ai-title'ı (slug)
Elle /rename yapılırsa (transcript'teki son custom-title bizim yazdığımız değilse) o session'a bir daha dokunmaz.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

STATE_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "auto-session-title"
KEY_RE = re.compile(r"\b(GR|YLC)-\d+\b", re.IGNORECASE)
TR = str.maketrans("çğıöşüÇĞİÖŞÜ", "cgiosucgiosu")
MAX_LEN = 60


def slugify(text: str) -> str:
    text = text.translate(TR).lower()
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text


def last_record(transcript: str, rtype: str, field: str) -> str | None:
    try:
        out = subprocess.run(
            ["grep", "-o", f'"type":"{rtype}","{field}":"[^"]*"', transcript],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip().splitlines()
    except Exception:
        return None
    if not out:
        return None
    return out[-1].rsplit(f'"{field}":"', 1)[1][:-1]


def git_branch(cwd: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", cwd, "branch", "--show-current"],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
    except Exception:
        return ""


def main() -> None:
    if os.environ.get("AUTO_SESSION_TITLE_DISABLE"):
        return
    data = json.load(sys.stdin)
    if data.get("source", "user") != "user":
        return
    sid = data.get("session_id")
    transcript = data.get("transcript_path") or ""
    if not sid:
        return

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state_file = STATE_DIR / f"{sid}.json"
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    if state.get("locked"):
        return

    current = last_record(transcript, "custom-title", "customTitle") if transcript else None
    if current and current != state.get("last_set"):
        state["locked"] = True
        state_file.write_text(json.dumps(state))
        return

    branch = git_branch(data.get("cwd") or os.getcwd())
    key, desc = None, None
    if m := KEY_RE.search(branch):
        key = m.group(0).upper()
        desc = slugify(branch[m.end():]) or None
    elif m := KEY_RE.search(data.get("prompt", "")):
        key = m.group(0).upper()
    else:
        key = state.get("key")

    if not desc and transcript:
        ai = last_record(transcript, "ai-title", "aiTitle")
        if ai:
            desc = slugify(KEY_RE.sub("", ai)) or None

    title = "-".join(p for p in (key, desc) if p)[:MAX_LEN].rstrip("-")
    if not title or title == state.get("last_set"):
        return

    state.update(key=key, last_set=title)
    state_file.write_text(json.dumps(state))
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
