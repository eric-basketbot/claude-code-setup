#!/usr/bin/env python3
"""UserPromptSubmit hook — every 15 min of active use, write a session snapshot.

Snapshot = last ~40 user+assistant text messages as plain prose, into
memory/meta/session_snapshots/<session_id>.md. Also appends a breadcrumb line
to memory/meta/session_log.md.

Fast-exits in <5ms when throttle says "not yet," so repeated prompts are cheap.
No-ops for any cwd whose project does not have a memory/ directory bootstrapped.
Never blocks: any error exits 0.

Project resolution: derives the per-project Claude data dir from the hook
payload's `cwd` field via the standard slug encoding (`-Users-foo-Proj`). Skips
silently if no memory/ exists under that dir.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

INTERVAL_SECONDS = 15 * 60  # 15 minutes
MAX_MESSAGES = 40
MAX_CHARS_PER_MESSAGE = 2000

PROJECTS_BASE = Path.home() / ".claude" / "projects"
HOOKS_DIR = Path.home() / ".claude" / "hooks"

LOG_HEADER = (
    "---\n"
    "name: Session log\n"
    "description: One-line pre-compaction checkpoints so cross-session recall survives context compaction\n"
    "type: reference\n"
    "scope: on-demand\n"
    "---\n\n"
)


def _project_slug(cwd: str) -> str:
    """Encode a project root path as Claude's directory slug: /Users/foo/Bar -> -Users-foo-Bar."""
    return "-" + cwd.strip("/").replace("/", "-")


def _resolve_memory_dir(cwd: str) -> Path | None:
    """Return the memory dir for this cwd, or None if not bootstrapped."""
    if not cwd:
        return None
    slug = _project_slug(cwd)
    memdir = PROJECTS_BASE / slug / "memory"
    return memdir if memdir.exists() else None


def _throttle_path(cwd: str) -> Path:
    """Per-project throttle file — keyed on a short hash of cwd."""
    h = hashlib.sha1(cwd.encode("utf-8")).hexdigest()[:12]
    return HOOKS_DIR / f".session_save_ts.{h}"


def _throttle_elapsed(throttle: Path) -> bool:
    try:
        age = time.time() - throttle.stat().st_mtime
        return age >= INTERVAL_SECONDS
    except FileNotFoundError:
        return True
    except Exception:
        return False


def _touch_throttle(throttle: Path) -> None:
    try:
        throttle.parent.mkdir(parents=True, exist_ok=True)
        throttle.touch()
        os.utime(throttle, None)
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


def _write_snapshot(snapshot_dir: Path, session_id: str, msgs: list[tuple[str, str]]) -> None:
    snapshot_dir.mkdir(parents=True, exist_ok=True)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    fname = snapshot_dir / f"{today}_{session_id[:8]}.md"
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


def _append_breadcrumb(log_file: Path, session_id: str, message_count: int, topic: str) -> None:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    if not log_file.exists():
        log_file.write_text(LOG_HEADER, encoding="utf-8")
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    topic = topic.replace("\n", " ").replace("|", "/")
    if len(topic) > 80:
        topic = topic[:77] + "..."
    with log_file.open("a", encoding="utf-8") as f:
        f.write(
            f"- {ts} | session={session_id[:8]} | checkpoint=interval"
            f" | messages={message_count} | topic={topic}\n"
        )


def main() -> int:
    try:
        raw = sys.stdin.read()
    except Exception:
        return 0
    try:
        payload = json.loads(raw) if raw else {}
    except Exception:
        return 0

    cwd = payload.get("cwd", "") or ""
    memdir = _resolve_memory_dir(cwd)
    if memdir is None:
        return 0

    throttle = _throttle_path(cwd)
    if not _throttle_elapsed(throttle):
        return 0

    session_id = (payload.get("session_id") or "unknown")
    transcript_path = payload.get("transcript_path") or ""

    msgs = _collect_messages(transcript_path, MAX_MESSAGES)
    if not msgs:
        _touch_throttle(throttle)
        return 0

    try:
        _write_snapshot(memdir / "meta" / "session_snapshots", session_id, msgs)
        first_user = next((t for r, t in msgs if r == "user"), "")
        _append_breadcrumb(memdir / "meta" / "session_log.md", session_id, len(msgs), first_user)
    except Exception:
        return 0
    finally:
        _touch_throttle(throttle)

    return 0


if __name__ == "__main__":
    sys.exit(main())
