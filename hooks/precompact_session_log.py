#!/usr/bin/env python3
"""PreCompact hook — append a one-line session checkpoint to the project's session log.

Reads the PreCompact event JSON from stdin. No-ops unless cwd is inside the bound project.
Never blocks compaction: any error exits 0.
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

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
LOG_FILE = MEMORY_DIR / "meta" / "session_log.md"
HEADER = (
    "---\n"
    "name: Session log\n"
    "description: One-line pre-compaction checkpoints so cross-session recall survives context compaction\n"
    "type: reference\n"
    "scope: on-demand\n"
    "---\n\n"
)


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
    if PROJECT_NAME not in cwd:
        return 0

    session_id = (payload.get("session_id") or "unknown")[:8]
    trigger = payload.get("trigger") or "auto"
    transcript_path = payload.get("transcript_path") or ""

    topic = _first_user_message(transcript_path)
    topic = topic.replace("\n", " ").replace("|", "/")
    if len(topic) > 80:
        topic = topic[:77] + "..."

    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        if not LOG_FILE.exists():
            LOG_FILE.write_text(HEADER, encoding="utf-8")
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"- {ts} | session={session_id} | trigger={trigger} | topic={topic}\n")
    except Exception:
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
