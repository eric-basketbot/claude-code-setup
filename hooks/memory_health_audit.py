#!/usr/bin/env python3
"""Claude memory health audit.

Run modes:
  (no flag)   report-only — writes memory_health_report.md, never mutates
  --apply     apply safe mutations AND write report

Safe mutations:
  1. Quarantine stale files (365+ days old, not scope:always-apply, not in user/
     or meta/ or completed/ folders, not referenced from MEMORY.md) into
     memory-repository/<today>/archived/<rel-path>.
  2. Rotate memory/meta/session_log.md if > ROTATE_LINES lines — move oldest
     ~80% to memory/meta/session_log_archive_<today>.md, keep last KEEP_LINES
     in the active file (frontmatter preserved).
  3. Quarantine session snapshots older than SNAPSHOT_AGE_DAYS into
     memory-repository/<today>/snapshots/<filename>.
  4. Permanently delete memory-repository entries older than REPO_KEEP_DAYS.

Safety:
  - Every mutation funnels through memory-repository/ (outside memory/). The
    file leaves memory/ only by passing through quarantine first.
  - Max MUTATION_CAP mutations per run. If the audit wants to exceed the cap,
    it halts and reports instead.
  - Every action appended to memory/meta/memory_cleanup_log.md.
  - Idempotent: running twice is a no-op.

Project selection:
  - $CLAUDE_MEMORY_PROJECT_DIR — explicit path to the project under ~/.claude/projects/
  - $CLAUDE_PROJECT_DIR — Claude Code's standard project-dir env var (will be
    converted to the path-encoded slug under ~/.claude/projects/)
  - --project-dir <path> — CLI override
  - Fallback: the most-recently-modified directory under ~/.claude/projects/
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ---- project resolution ---------------------------------------------------
def _resolve_project_dir(cli_arg: str | None) -> Path:
    """Resolve the per-project Claude data directory.

    Precedence: CLI arg → $CLAUDE_MEMORY_PROJECT_DIR → $CLAUDE_PROJECT_DIR (slugified)
    → most-recent under ~/.claude/projects/.
    """
    if cli_arg:
        return Path(cli_arg).expanduser().resolve()

    env = os.environ.get("CLAUDE_MEMORY_PROJECT_DIR")
    if env:
        return Path(env).expanduser().resolve()

    project_root = os.environ.get("CLAUDE_PROJECT_DIR")
    base = Path.home() / ".claude" / "projects"
    if project_root:
        # Claude Code path-encodes project dirs as -Users-foo-bar-Project
        slug = "-" + str(Path(project_root).resolve()).strip("/").replace("/", "-")
        candidate = base / slug
        if candidate.exists():
            return candidate

    if not base.exists():
        print(f"ERROR: {base} does not exist — no Claude projects found.", file=sys.stderr)
        sys.exit(2)

    # Fall back to most recently modified project dir.
    dirs = [d for d in base.iterdir() if d.is_dir()]
    if not dirs:
        print(f"ERROR: no project dirs under {base}", file=sys.stderr)
        sys.exit(2)
    dirs.sort(key=lambda d: d.stat().st_mtime, reverse=True)
    return dirs[0]


# ---- tuning ---------------------------------------------------------------
VALID_TYPES = {"user", "feedback", "project", "reference"}
REQUIRED_FRONTMATTER = ("name", "description", "type")
STALE_DAYS = 365          # file quarantine threshold
SNAPSHOT_AGE_DAYS = 60    # snapshot quarantine threshold
REPO_KEEP_DAYS = 180      # final-delete threshold
ROTATE_LINES = 500        # session_log.md rotation threshold
KEEP_LINES = 100          # lines kept in active session_log.md after rotation
MUTATION_CAP = 50         # hard cap per run
AUTO_LOAD_CAP = 200
AUTO_LOAD_WARN = 180
PROTECTED_TOP_DIRS = {"user", "meta", "completed"}  # never quarantined
LAUNCHD_LABEL = os.environ.get("CLAUDE_MEMORY_LAUNCHD_LABEL", "com.example.claude-memory-health")

FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)
LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")

# Globals populated in main() after project resolution.
PROJECT_DIR: Path
MEMORY_DIR: Path
REPO_DIR: Path
MEMORY_INDEX: Path
REPORT_FILE: Path
SESSION_LOG: Path
CLEANUP_LOG: Path
SNAPSHOTS_DIR: Path


def _bind_paths(project_dir: Path) -> None:
    global PROJECT_DIR, MEMORY_DIR, REPO_DIR, MEMORY_INDEX, REPORT_FILE
    global SESSION_LOG, CLEANUP_LOG, SNAPSHOTS_DIR
    PROJECT_DIR = project_dir
    MEMORY_DIR = PROJECT_DIR / "memory"
    REPO_DIR = PROJECT_DIR / "memory-repository"
    MEMORY_INDEX = MEMORY_DIR / "MEMORY.md"
    REPORT_FILE = MEMORY_DIR / "meta" / "memory_health_report.md"
    SESSION_LOG = MEMORY_DIR / "meta" / "session_log.md"
    CLEANUP_LOG = MEMORY_DIR / "meta" / "memory_cleanup_log.md"
    SNAPSHOTS_DIR = MEMORY_DIR / "meta" / "session_snapshots"


# ---- helpers --------------------------------------------------------------
def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _parse_frontmatter(text: str) -> dict[str, str]:
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}
    out: dict[str, str] = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip()] = v.strip()
    return out


def _iter_memory_files() -> list[Path]:
    return sorted(p for p in MEMORY_DIR.rglob("*.md") if p.name != "MEMORY.md")


def _index_referenced_paths() -> set[Path]:
    out: set[Path] = set()
    if not MEMORY_INDEX.exists():
        return out
    text = MEMORY_INDEX.read_text(encoding="utf-8")
    for m in LINK_RE.finditer(text):
        target = m.group(2).split("#", 1)[0].strip()
        if not target or target.startswith(("http://", "https://", "mailto:")):
            continue
        try:
            out.add((MEMORY_DIR / target).resolve())
        except Exception:
            pass
    return out


def _append_cleanup_log(lines: list[str]) -> None:
    if not lines:
        return
    CLEANUP_LOG.parent.mkdir(parents=True, exist_ok=True)
    if not CLEANUP_LOG.exists():
        CLEANUP_LOG.write_text(
            "---\n"
            "name: Memory cleanup log\n"
            "description: Append-only record of every mutation made by memory_health_audit.py --apply\n"
            "type: reference\n"
            "scope: on-demand\n"
            "---\n\n",
            encoding="utf-8",
        )
    with CLEANUP_LOG.open("a", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")


# ---- report checks (read-only) --------------------------------------------
def _check_index() -> tuple[list[str], list[str], int]:
    if not MEMORY_INDEX.exists():
        return ["MEMORY.md is missing"], [], 0
    text = MEMORY_INDEX.read_text(encoding="utf-8")
    lines = text.splitlines()
    line_count = len(lines)
    issues: list[str] = []
    link_issues: list[str] = []
    if line_count > AUTO_LOAD_CAP:
        issues.append(
            f"MEMORY.md has {line_count} lines — exceeds auto-load cap of {AUTO_LOAD_CAP}"
        )
    elif line_count > AUTO_LOAD_WARN:
        issues.append(
            f"MEMORY.md has {line_count} lines — approaching auto-load cap of {AUTO_LOAD_CAP}"
        )
    for m in LINK_RE.finditer(text):
        target = m.group(2).split("#", 1)[0].strip()
        if not target or target.startswith(("http://", "https://", "mailto:")):
            continue
        if not (MEMORY_DIR / target).exists():
            link_issues.append(f"broken link in MEMORY.md → {target}")
    return link_issues, issues, line_count


def _scan_files(index_paths: set[Path]) -> dict:
    missing_fm: list[str] = []
    bad_type: list[str] = []
    always_apply_not_indexed: list[str] = []
    total = 0
    for f in _iter_memory_files():
        total += 1
        rel = f.relative_to(MEMORY_DIR)
        try:
            text = f.read_text(encoding="utf-8")
        except Exception:
            missing_fm.append(f"{rel} (unreadable)")
            continue
        fm = _parse_frontmatter(text)
        missing_keys = [k for k in REQUIRED_FRONTMATTER if k not in fm]
        if missing_keys:
            missing_fm.append(f"{rel} — missing {', '.join(missing_keys)}")
        t = fm.get("type", "")
        if t and t not in VALID_TYPES:
            bad_type.append(f"{rel} — type={t!r}")
        if fm.get("scope") == "always-apply":
            if f.resolve() not in index_paths:
                always_apply_not_indexed.append(str(rel))
    return {
        "total": total,
        "missing_fm": missing_fm,
        "bad_type": bad_type,
        "always_apply_not_indexed": always_apply_not_indexed,
    }


# ---- mutation candidates --------------------------------------------------
def _find_stale_files(index_paths: set[Path]) -> list[Path]:
    cutoff = time.time() - STALE_DAYS * 86400
    out: list[Path] = []
    for f in _iter_memory_files():
        rel = f.relative_to(MEMORY_DIR)
        top = rel.parts[0] if rel.parts else ""
        if top in PROTECTED_TOP_DIRS:
            continue
        try:
            text = f.read_text(encoding="utf-8")
        except Exception:
            continue
        fm = _parse_frontmatter(text)
        if fm.get("scope") == "always-apply":
            continue
        if f.resolve() in index_paths:
            continue
        if f.stat().st_mtime > cutoff:
            continue
        out.append(f)
    return out


def _find_old_snapshots() -> list[Path]:
    if not SNAPSHOTS_DIR.exists():
        return []
    cutoff = time.time() - SNAPSHOT_AGE_DAYS * 86400
    out: list[Path] = []
    for f in SNAPSHOTS_DIR.glob("*.md"):
        try:
            if f.stat().st_mtime <= cutoff:
                out.append(f)
        except Exception:
            pass
    return out


def _find_expired_repo_dirs() -> list[Path]:
    """Return repository date folders where the folder's mtime is > REPO_KEEP_DAYS old."""
    if not REPO_DIR.exists():
        return []
    cutoff = time.time() - REPO_KEEP_DAYS * 86400
    out: list[Path] = []
    for d in REPO_DIR.iterdir():
        if not d.is_dir():
            continue
        try:
            datetime.strptime(d.name, "%Y-%m-%d")
        except ValueError:
            continue
        try:
            if d.stat().st_mtime <= cutoff:
                out.append(d)
        except Exception:
            pass
    return out


# ---- mutations ------------------------------------------------------------
def _quarantine(src: Path, kind: str, cleanup_lines: list[str]) -> bool:
    """Move src into memory-repository/<today>/<kind>/<relative-path>."""
    try:
        if kind == "archived":
            rel = src.relative_to(MEMORY_DIR)
        elif kind == "snapshots":
            rel = Path(src.name)
        else:
            return False
        dest = REPO_DIR / _today() / kind / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dest))
        (REPO_DIR / _today()).touch()
        cleanup_lines.append(
            f"- {_now_iso()} | action=quarantine | kind={kind} | from={rel} | to={dest.relative_to(PROJECT_DIR)}"
        )
        return True
    except Exception as e:
        cleanup_lines.append(
            f"- {_now_iso()} | action=quarantine-FAILED | kind={kind} | src={src} | error={e}"
        )
        return False


def _rotate_session_log(cleanup_lines: list[str]) -> bool:
    if not SESSION_LOG.exists():
        return False
    try:
        text = SESSION_LOG.read_text(encoding="utf-8")
    except Exception:
        return False
    lines = text.splitlines()
    if len(lines) <= ROTATE_LINES:
        return False

    m = FRONTMATTER_RE.match(text)
    if m:
        fm_block = text[: m.end()]
        body_lines = text[m.end():].splitlines()
    else:
        fm_block = ""
        body_lines = lines

    keep = body_lines[-KEEP_LINES:]
    archive = body_lines[:-KEEP_LINES]

    archive_path = SESSION_LOG.parent / f"session_log_archive_{_today()}.md"
    try:
        archive_text = (
            "---\n"
            "name: Session log archive\n"
            f"description: Rotated from session_log.md on {_today()} — older entries\n"
            "type: reference\n"
            "scope: on-demand\n"
            "---\n\n"
        )
        archive_text += "\n".join(archive).lstrip() + "\n"
        archive_path.write_text(archive_text, encoding="utf-8")
        new_log = fm_block + "\n".join(keep).lstrip() + "\n"
        SESSION_LOG.write_text(new_log, encoding="utf-8")
        cleanup_lines.append(
            f"- {_now_iso()} | action=rotate-session-log | archived_lines={len(archive)} | kept_lines={len(keep)} | to={archive_path.relative_to(PROJECT_DIR)}"
        )
        return True
    except Exception as e:
        cleanup_lines.append(
            f"- {_now_iso()} | action=rotate-session-log-FAILED | error={e}"
        )
        return False


def _purge_expired_repo(cleanup_lines: list[str]) -> int:
    count = 0
    for d in _find_expired_repo_dirs():
        try:
            shutil.rmtree(d)
            cleanup_lines.append(
                f"- {_now_iso()} | action=final-delete | target={d.relative_to(PROJECT_DIR)} | age_days>{REPO_KEEP_DAYS}"
            )
            count += 1
        except Exception as e:
            cleanup_lines.append(
                f"- {_now_iso()} | action=final-delete-FAILED | target={d} | error={e}"
            )
    return count


def _apply_mutations(index_paths: set[Path]) -> dict:
    cleanup_lines: list[str] = []
    counts = {
        "stale_quarantined": 0,
        "snapshots_quarantined": 0,
        "session_log_rotated": 0,
        "repo_dirs_deleted": 0,
        "halted": False,
        "halt_reason": "",
    }

    stale = _find_stale_files(index_paths)
    old_snapshots = _find_old_snapshots()

    total_quarantines = len(stale) + len(old_snapshots)
    if total_quarantines > MUTATION_CAP:
        counts["halted"] = True
        counts["halt_reason"] = (
            f"wants to quarantine {total_quarantines} files ({len(stale)} stale + "
            f"{len(old_snapshots)} snapshots) — exceeds cap of {MUTATION_CAP}. "
            "No mutations applied. Resolve manually or raise MUTATION_CAP."
        )
        cleanup_lines.append(
            f"- {_now_iso()} | action=HALTED | reason={counts['halt_reason']}"
        )
        _append_cleanup_log(cleanup_lines)
        return counts

    for f in stale:
        if _quarantine(f, "archived", cleanup_lines):
            counts["stale_quarantined"] += 1
    for f in old_snapshots:
        if _quarantine(f, "snapshots", cleanup_lines):
            counts["snapshots_quarantined"] += 1

    if _rotate_session_log(cleanup_lines):
        counts["session_log_rotated"] = 1

    counts["repo_dirs_deleted"] = _purge_expired_repo(cleanup_lines)

    _append_cleanup_log(cleanup_lines)
    return counts


# ---- report ---------------------------------------------------------------
def _format_section(title: str, items: list[str], empty_msg: str = "none") -> str:
    if not items:
        return f"### {title}\n\n{empty_msg}\n"
    body = "\n".join(f"- {x}" for x in items[:100])
    more = f"\n\n_(+ {len(items) - 100} more — list truncated at 100)_" if len(items) > 100 else ""
    return f"### {title} ({len(items)})\n\n{body}{more}\n"


def _write_report(
    mode: str,
    link_issues: list[str],
    index_issues: list[str],
    line_count: int,
    scan: dict,
    session_log_lines: int,
    mutation_counts: dict | None,
) -> int:
    issue_total = (
        len(link_issues)
        + len(index_issues)
        + len(scan["missing_fm"])
        + len(scan["bad_type"])
        + len(scan["always_apply_not_indexed"])
    )
    health = "green" if issue_total == 0 else ("yellow" if issue_total < 20 else "red")

    report = [
        "---",
        "name: Memory health report",
        f"description: Auto-generated periodically by launchd ({LAUNCHD_LABEL}), mode={mode}",
        "type: reference",
        "scope: on-demand",
        "---",
        "",
        f"# Memory health report — {_now_iso()}",
        "",
        f"- **Mode**: `{mode}`",
        f"- **Status**: {health.upper()} ({issue_total} report-only issue{'s' if issue_total != 1 else ''})",
        f"- **Total memory files**: {scan['total']}",
        f"- **MEMORY.md lines**: {line_count} (cap {AUTO_LOAD_CAP}, warn {AUTO_LOAD_WARN})",
        f"- **session_log.md lines**: {session_log_lines}",
        "",
    ]

    if mutation_counts is not None:
        report.append("## Mutations applied this run")
        report.append("")
        if mutation_counts.get("halted"):
            report.append(f"**HALTED — no mutations applied.** {mutation_counts['halt_reason']}")
        else:
            report.append(f"- Stale files quarantined (365+ days): **{mutation_counts['stale_quarantined']}**")
            report.append(f"- Session snapshots quarantined (60+ days): **{mutation_counts['snapshots_quarantined']}**")
            report.append(f"- session_log.md rotated: **{mutation_counts['session_log_rotated']}**")
            report.append(f"- Expired repository date-folders deleted (>180 days): **{mutation_counts['repo_dirs_deleted']}**")
        report.append("")
        report.append("See `memory/meta/memory_cleanup_log.md` for per-action details.")
        report.append(f"Quarantined files live in `memory-repository/` for {REPO_KEEP_DAYS} days before final deletion.")
        report.append("")

    report += [
        "## Report-only issues (not auto-fixed)",
        "",
        _format_section("MEMORY.md issues", index_issues),
        _format_section("Broken links in MEMORY.md", link_issues),
        _format_section("Files missing required frontmatter", scan["missing_fm"]),
        _format_section("Files with unknown `type:` value", scan["bad_type"]),
        _format_section(
            "Files marked `scope: always-apply` but not referenced in MEMORY.md",
            scan["always_apply_not_indexed"],
        ),
        "",
        "---",
        "",
        f"_Launchd job: `{LAUNCHD_LABEL}` (every 12h)._",
        f"_Run mode: `{mode}`. Run `python3 ~/.claude/hooks/memory_health_audit.py` (no flag) for report-only dry runs._",
        f"_Disable: `launchctl unload ~/Library/LaunchAgents/{LAUNCHD_LABEL}.plist`_",
        "",
    ]

    REPORT_FILE.parent.mkdir(parents=True, exist_ok=True)
    REPORT_FILE.write_text("\n".join(report), encoding="utf-8")
    return issue_total


def _session_log_lines() -> int:
    if not SESSION_LOG.exists():
        return 0
    try:
        return sum(1 for _ in SESSION_LOG.open("r", encoding="utf-8"))
    except Exception:
        return 0


def _append_session_breadcrumb(mode: str, health: str, issue_total: int, counts: dict | None, total_files: int, line_count: int) -> None:
    try:
        if not SESSION_LOG.exists():
            SESSION_LOG.write_text(
                "---\n"
                "name: Session log\n"
                "description: One-line pre-compaction checkpoints so cross-session recall survives context compaction\n"
                "type: reference\n"
                "scope: on-demand\n"
                "---\n\n",
                encoding="utf-8",
            )
        with SESSION_LOG.open("a", encoding="utf-8") as f:
            applied = ""
            if counts is not None and not counts.get("halted"):
                applied_total = (
                    counts["stale_quarantined"]
                    + counts["snapshots_quarantined"]
                    + counts["session_log_rotated"]
                    + counts["repo_dirs_deleted"]
                )
                applied = f" | mutations={applied_total}"
            elif counts is not None and counts.get("halted"):
                applied = " | mutations=HALTED"
            f.write(
                f"- {_now_iso()} | checkpoint=health-audit | mode={mode} | status={health}"
                f" | issues={issue_total} | files={total_files} | memory_md_lines={line_count}{applied}\n"
            )
    except Exception:
        pass


# ---- main -----------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description="Claude memory health audit")
    ap.add_argument("--apply", action="store_true", help="apply safe mutations (default: report-only)")
    ap.add_argument("--project-dir", help="override the project dir under ~/.claude/projects/")
    args = ap.parse_args()
    mode = "apply" if args.apply else "report-only"

    project_dir = _resolve_project_dir(args.project_dir)
    if not project_dir.exists():
        print(f"ERROR: resolved project_dir {project_dir} does not exist", file=sys.stderr)
        return 2
    _bind_paths(project_dir)
    if not MEMORY_DIR.exists():
        print(f"ERROR: memory dir {MEMORY_DIR} does not exist — run the memory bootstrap first", file=sys.stderr)
        return 2

    link_issues, index_issues, line_count = _check_index()
    index_paths = _index_referenced_paths()

    mutation_counts: dict | None = None
    if args.apply:
        mutation_counts = _apply_mutations(index_paths)
        link_issues, index_issues, line_count = _check_index()
        index_paths = _index_referenced_paths()

    scan = _scan_files(index_paths)
    sl_lines = _session_log_lines()
    issue_total = _write_report(
        mode, link_issues, index_issues, line_count, scan, sl_lines, mutation_counts
    )
    health = "green" if issue_total == 0 else ("yellow" if issue_total < 20 else "red")
    _append_session_breadcrumb(mode, health, issue_total, mutation_counts, scan["total"], line_count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
