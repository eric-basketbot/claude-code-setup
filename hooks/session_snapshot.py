#!/usr/bin/env python3
"""UserPromptSubmit hook — every 15 min of active use, write a session snapshot.

Snapshot = last ~40 user+assistant text messages as plain prose, into
memory/meta/session_snapshots/<session_id>.md. Also appends a breadcrumb line
to memory/meta/session_log.md.

Fast-exits in <5ms when throttle says "not yet," so repeated prompts are cheap.
No-ops for any cwd outside the bound project. Never blocks: any error exits 0.
"""
from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

INTERVAL_SECONDS = 15 * 60  # 15 minutes
MAX_MESSAGES = 40           # last N user+assistant messages in snapshot
MAX_CHARS_PER_MESSAGE = 2000  # truncate very long messages in snapshot

# ---- project binding -------------------------------------------------------
# Point this at YOUR repo. Claude Code stores per-project state under
# ~/.claude/projects/<abs-path-with-slashes-replaced-by-dashes>/, so the slug is
# derived rather than hardcoded. Override with AI_MEMORY_PROJECT_ROOT.
PROJECT_ROOT = Path(
    os.environ.get("AI_MEMORY_PROJECT_ROOT", str(Path.home() / "src/your-project"))
).expanduser()
PROJECT_NAME = PROJECT_ROOT.name
PROJECT_DIR = (
    Path.home() / ".claude" / "projects" / str(PROJECT_ROOT).replace("/", "-")
)
MEMORY_DIR = PROJECT_DIR / "memory"
SNAPSHOT_DIR = MEMORY_DIR / "meta" / "session_snapshots"
LOG_FILE = MEMORY_DIR / "meta" / "session_log.md"
THROTTLE_FILE = Path("$HOME/.claude/hooks/.ai_session_save_ts")

LOG_HEADER = (
    "---\n"
    "name: Session log\n"
    "description: One-line pre-compaction checkpoints so cross-session recall survives context compaction\n"
    "type: reference\n"
    "scope: on-demand\n"
    "---\n\n"
)


def _throttle_elapsed() -> bool:
    """Return True if it's been >= INTERVAL_SECONDS since last save (or never)."""
    try:
        age = time.time() - THROTTLE_FILE.stat().st_mtime
        return age >= INTERVAL_SECONDS
    except FileNotFoundError:
        return True
    except Exception:
        return False


def _touch_throttle() -> None:
    try:
        THROTTLE_FILE.parent.mkdir(parents=True, exist_ok=True)
        THROTTLE_FILE.touch()
        os.utime(THROTTLE_FILE, None)
    except Exception:
        pass


def _extract_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict):
                if block.get("type") == "text":
                    t = block.get("text", "")
                    if isinstance(t, str) and t.strip():
                        parts.append(t)
        return "\n".join(parts)
    return ""


def _collect_messages(transcript_path: str, limit: int) -> list[tuple[str, str]]:
    """Return the last `limit` (role, text) pairs from the transcript."""
    if not transcript_path:
        return []
    p = Path(transcript_path)
    if not p.exists():
        return []
    msgs: list[tuple[str, str]] = []
    try:
        with p.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    evt = json.loads(line)
                except Exception:
                    continue
                kind = evt.get("type")
                if kind not in ("user", "assistant"):
                    continue
                msg = evt.get("message") or {}
                content = msg.get("content") if isinstance(msg, dict) else None
                text = _extract_text(content).strip()
                if not text:
                    continue
                if len(text) > MAX_CHARS_PER_MESSAGE:
                    text = text[: MAX_CHARS_PER_MESSAGE - 20] + "\n[...truncated...]"
                msgs.append((kind, text))
    except Exception:
        return msgs
    return msgs[-limit:]


def _write_snapshot(session_id: str, msgs: list[tuple[str, str]]) -> None:
    SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    fname = SNAPSHOT_DIR / f"{today}_{session_id[:8]}.md"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    lines = [
        "---",
        "name: Session snapshot",
        f"description: Rolling conversation snapshot for session {session_id[:8]} (overwritten every 15 min)",
        "type: reference",
        "scope: on-demand",
        "---",
        "",
        f"# Session {session_id[:8]} — last updated {now}",
        f"Captured {len(msgs)} most recent user/assistant messages.",
        "",
    ]
    for role, text in msgs:
        lines.append(f"## {role}")
        lines.append("")
        lines.append(text)
        lines.append("")
    fname.write_text("\n".join(lines), encoding="utf-8")


def _append_breadcrumb(session_id: str, message_count: int, topic: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    if not LOG_FILE.exists():
        LOG_FILE.write_text(LOG_HEADER, encoding="utf-8")
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    topic = topic.replace("\n", " ").replace("|", "/")
    if len(topic) > 80:
        topic = topic[:77] + "..."
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(
            f"- {ts} | session={session_id[:8]} | checkpoint=interval"
            f" | messages={message_count} | topic={topic}\n"
        )


def main() -> int:
    if not _throttle_elapsed():
        return 0

    try:
        raw = sys.stdin.read()
    except Exception:
        return 0
    try:
        payload = json.loads(raw) if raw else {}
    except Exception:
        return 0

    cwd = payload.get("cwd", "") or ""
    if PROJECT_NAME not in cwd:
        return 0

    session_id = (payload.get("session_id") or "unknown")
    transcript_path = payload.get("transcript_path") or ""

    msgs = _collect_messages(transcript_path, MAX_MESSAGES)
    if not msgs:
        # nothing to snapshot yet, but still touch throttle so we don't retry every prompt
        _touch_throttle()
        return 0

    try:
        _write_snapshot(session_id, msgs)
        first_user = next((t for r, t in msgs if r == "user"), "")
        _append_breadcrumb(session_id, len(msgs), first_user)
    except Exception:
        return 0
    finally:
        _touch_throttle()

    return 0


if __name__ == "__main__":
    sys.exit(main())
