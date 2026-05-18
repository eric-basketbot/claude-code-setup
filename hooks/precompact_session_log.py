#!/usr/bin/env python3
"""PreCompact hook — append a one-line session checkpoint to the project's session log.

Reads the PreCompact event JSON from stdin. No-ops unless the cwd's project has a
memory/ directory bootstrapped under ~/.claude/projects/<slug>/. Never blocks
compaction: any error exits 0.
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

PROJECTS_BASE = Path.home() / ".claude" / "projects"
HEADER = (
    "---\n"
    "name: Session log\n"
    "description: One-line pre-compaction checkpoints so cross-session recall survives context compaction\n"
    "type: reference\n"
    "scope: on-demand\n"
    "---\n\n"
)


def _project_slug(cwd: str) -> str:
    return "-" + cwd.strip("/").replace("/", "-")


def _resolve_log_file(cwd: str) -> Path | None:
    if not cwd:
        return None
    memdir = PROJECTS_BASE / _project_slug(cwd) / "memory"
    if not memdir.exists():
        return None
    return memdir / "meta" / "session_log.md"


def _first_user_message(transcript_path: str) -> str:
    if not transcript_path:
        return ""
    p = Path(transcript_path)
    if not p.exists():
        return ""
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
                if evt.get("type") != "user":
                    continue
                msg = evt.get("message", {})
                content = msg.get("content") if isinstance(msg, dict) else None
                if isinstance(content, str) and content.strip():
                    return content.strip()
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "text":
                            text = block.get("text", "")
                            if isinstance(text, str) and text.strip():
                                return text.strip()
    except Exception:
        return ""
    return ""


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
    log_file = _resolve_log_file(cwd)
    if log_file is None:
        return 0

    session_id = (payload.get("session_id") or "unknown")[:8]
    trigger = payload.get("trigger") or "auto"
    transcript_path = payload.get("transcript_path") or ""

    topic = _first_user_message(transcript_path)
    topic = topic.replace("\n", " ").replace("|", "/")
    if len(topic) > 80:
        topic = topic[:77] + "..."

    try:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        if not log_file.exists():
            log_file.write_text(HEADER, encoding="utf-8")
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with log_file.open("a", encoding="utf-8") as f:
            f.write(f"- {ts} | session={session_id} | trigger={trigger} | topic={topic}\n")
    except Exception:
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
