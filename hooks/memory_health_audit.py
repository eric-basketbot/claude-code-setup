#!/usr/bin/env python3
"""Memory health audit.

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
"""
from __future__ import annotations

import argparse
import re
import shutil
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ---- paths ----------------------------------------------------------------
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
REPO_DIR = PROJECT_DIR / "memory-repository"
MEMORY_INDEX = MEMORY_DIR / "MEMORY.md"
REPORT_FILE = MEMORY_DIR / "meta" / "memory_health_report.md"
SESSION_LOG = MEMORY_DIR / "meta" / "session_log.md"
CLEANUP_LOG = MEMORY_DIR / "meta" / "memory_cleanup_log.md"
SNAPSHOTS_DIR = MEMORY_DIR / "meta" / "session_snapshots"

# ---- tuning ---------------------------------------------------------------
VALID_TYPES = {"user", "feedback", "project", "reference"}
REQUIRED_FRONTMATTER = ("name", "description", "type")
STALE_DAYS = 365          # file quarantine threshold
SNAPSHOT_AGE_DAYS = 60    # snapshot quarantine threshold
SNAPSHOT_BATCH = 40       # max snapshots quarantined per run (stays under MUTATION_CAP)
REPO_KEEP_DAYS = 180      # final-delete threshold (user-requested)
ROTATE_LINES = 500        # session_log.md rotation threshold
KEEP_LINES = 100          # lines kept in active session_log.md after rotation
MUTATION_CAP = 50         # hard cap per run
AUTO_LOAD_CAP = 200
AUTO_LOAD_WARN = 180
MEMORY_BYTE_WARN = 14_000   # MEMORY.md loads first 200 lines / 25KB; 2026-07-25 breach was BYTES at 77 lines
MEMORY_BYTE_ERR = 16_000
TOPIC_INDEX_STUB_MAX = 2_048  # topic_index.md retired 2026-07-25 — flag regrowth
PROTECTED_TOP_DIRS = {"user", "meta", "completed"}  # never quarantined
REMINDERS_FILE = MEMORY_DIR / "meta" / "reference_dated_reminders.md"
STUB_MARKERS = ("**MOVED 2026", "⚠️ RETIRED")

FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)
LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")

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
    """Return every in-tree markdown file reachable from the root index.

    Topic indexes link to their detailed rules, so checking only direct links
    from MEMORY.md produces false "always-apply but not indexed" reports and
    can misclassify a reachable file as stale. Traverse the complete local
    markdown graph, resolve each link relative to the file containing it, and
    reject external or out-of-tree targets. Cycles are harmless.
    """
    out: set[Path] = set()
    if not MEMORY_INDEX.exists():
        return out

    memory_root = MEMORY_DIR.resolve()
    root_index = MEMORY_INDEX.resolve()
    pending = [root_index]
    visited = {root_index}

    while pending:
        source = pending.pop()
        try:
            text = source.read_text(encoding="utf-8")
        except Exception:
            continue

        for match in LINK_RE.finditer(text):
            target = match.group(2).split("#", 1)[0].strip()
            if (
                not target
                or target.startswith(("http://", "https://", "mailto:", "/"))
            ):
                continue
            try:
                candidate = (source.parent / target).resolve()
                candidate.relative_to(memory_root)
            except (OSError, RuntimeError, ValueError):
                continue

            if candidate.is_dir():
                candidate = candidate / "index.md"
            if (
                candidate == root_index
                or candidate.suffix.lower() != ".md"
                or not candidate.is_file()
            ):
                continue

            if candidate not in out:
                out.add(candidate)
            if candidate not in visited:
                visited.add(candidate)
                pending.append(candidate)
    return out


def _append_cleanup_log(lines: list[str]) -> None:
    if not lines:
        return
    CLEANUP_LOG.parent.mkdir(parents=True, exist_ok=True)
    if not CLEANUP_LOG.exists():
        CLEANUP_LOG.write_text(
            "---\n"
            "name: Memory cleanup log\n"
            "description: Append-only record of every mutation made by ai_memory_health_audit.py --apply\n"
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
    byte_count = len(text.encode("utf-8"))
    if byte_count >= MEMORY_BYTE_ERR:
        issues.append(
            f"MEMORY.md is {byte_count} bytes — over the {MEMORY_BYTE_ERR}-byte ceiling; "
            "move rationale to folder indexes NOW (the rule stays as a one-liner, the why moves)"
        )
    elif byte_count >= MEMORY_BYTE_WARN:
        issues.append(
            f"MEMORY.md is {byte_count} bytes — approaching the byte cap (warn {MEMORY_BYTE_WARN}); "
            "trim dense bullets before appending anything"
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
    scope_missing = 0
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
        elif "scope" not in fm:
            scope_missing += 1
    return {
        "total": total,
        "missing_fm": missing_fm,
        "bad_type": bad_type,
        "always_apply_not_indexed": always_apply_not_indexed,
        "scope_missing": scope_missing,
    }


def _check_structure() -> dict:
    """Structural checks added in the 2026-07-25 reorg (all report-only).

    - root closed: no .md at memory root except MEMORY.md (transition stubs listed
      separately and not counted as issues)
    - every top-level folder has an index.md
    - coverage: every file is linked from an index.md within its own folder tree
      (structural freshness — an index is stale when its link set no longer matches
      the filesystem, regardless of mtime)
    - topic_index.md stays a stub
    """
    root_files: list[str] = []
    root_stubs: list[str] = []
    missing_index: list[str] = []
    uncovered: list[str] = []

    for p in sorted(MEMORY_DIR.glob("*.md")):
        if p.name == "MEMORY.md":
            continue
        try:
            body = p.read_text(encoding="utf-8")
        except Exception:
            body = ""
        if p.name == "topic_index.md":
            if p.stat().st_size > TOPIC_INDEX_STUB_MAX:
                root_files.append(
                    f"topic_index.md regrew to {p.stat().st_size} bytes — it is a RETIRED stub; "
                    "move content into folder indexes"
                )
            continue
        if any(marker in body for marker in STUB_MARKERS):
            root_stubs.append(f"{p.name} (transition stub — reclaimable once nothing links the old path)")
        else:
            root_files.append(
                f"{p.name} — memory root is closed; move into its topic folder + index"
            )

    link_in_tree: dict[str, set[Path]] = {}
    for top in sorted(d for d in MEMORY_DIR.iterdir() if d.is_dir()):
        indexes = list(top.rglob("index.md"))
        if not (top / "index.md").exists():
            missing_index.append(f"{top.name}/ has no index.md")
        linked: set[Path] = set()
        for idx in indexes:
            try:
                text = idx.read_text(encoding="utf-8")
            except Exception:
                continue
            for m in LINK_RE.finditer(text):
                target = m.group(2).split("#", 1)[0].strip()
                if not target or target.startswith(("http://", "https://", "mailto:", "/")):
                    continue
                try:
                    linked.add((idx.parent / target).resolve())
                except (OSError, RuntimeError, ValueError):
                    continue
        link_in_tree[top.name] = linked

    for f in _iter_memory_files():
        rel = f.relative_to(MEMORY_DIR)
        if not rel.parts or len(rel.parts) == 1:
            continue  # root files handled above
        if "session_snapshots" in rel.parts or f.name == "index.md":
            continue
        top = rel.parts[0]
        if f.resolve() not in link_in_tree.get(top, set()):
            uncovered.append(f"{rel} — not linked from any index in {top}/")

    return {
        "root_files": root_files,
        "root_stubs": root_stubs,
        "missing_index": missing_index,
        "uncovered": uncovered,
    }


def _check_overdue_reminders() -> list[str]:
    """Flag dated reminders (meta/reference_dated_reminders.md) whose date has passed."""
    if not REMINDERS_FILE.exists():
        return []
    out: list[str] = []
    today = _today()
    date_re = re.compile(r"^-\s+\*\*~?(\d{4}-\d{2}-\d{2})")
    try:
        for line in REMINDERS_FILE.read_text(encoding="utf-8").splitlines():
            m = date_re.match(line.strip())
            if m and m.group(1) < today:
                out.append(f"overdue reminder ({m.group(1)}): {line.strip()[:140]}")
    except Exception:
        pass
    return out


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
    """Snapshots age by the YYYY-MM-DD in their filename, falling back to mtime.

    mtime alone is unreliable: the 2026-07-12 memory migration mass-touched every
    file, which silently froze snapshot quarantine for two months. Returns at most
    SNAPSHOT_BATCH oldest-first per run so a backlog drains under MUTATION_CAP
    instead of tripping the cap-halt.
    """
    if not SNAPSHOTS_DIR.exists():
        return []
    cutoff_dt = datetime.now(timezone.utc).timestamp() - SNAPSHOT_AGE_DAYS * 86400
    cutoff_name = datetime.fromtimestamp(cutoff_dt, tz=timezone.utc).strftime("%Y-%m-%d")
    dated: list[tuple[str, Path]] = []
    for f in SNAPSHOTS_DIR.glob("*.md"):
        name_date = f.name[:10]
        try:
            datetime.strptime(name_date, "%Y-%m-%d")
        except ValueError:
            try:
                if f.stat().st_mtime <= cutoff_dt:
                    dated.append(("0000-00-00", f))
            except Exception:
                pass
            continue
        if name_date <= cutoff_name:
            dated.append((name_date, f))
    dated.sort()
    return [f for _, f in dated[:SNAPSHOT_BATCH]]


def _find_expired_repo_dirs() -> list[Path]:
    """Return repository date folders where the folder's mtime is > REPO_KEEP_DAYS old."""
    if not REPO_DIR.exists():
        return []
    cutoff = time.time() - REPO_KEEP_DAYS * 86400
    out: list[Path] = []
    for d in REPO_DIR.iterdir():
        if not d.is_dir():
            continue
        # Validate YYYY-MM-DD name to avoid nuking anything unexpected
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
        # Touch the date folder so its mtime reflects last-write (used for expiry)
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

    # Split frontmatter from body
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
    """Run the 4 safe mutations under the MUTATION_CAP. Return counts per action."""
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

    # Cap check up-front — counts the two quarantine actions.
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
    structure: dict | None = None,
    overdue: list[str] | None = None,
) -> int:
    structure = structure or {"root_files": [], "root_stubs": [], "missing_index": [], "uncovered": []}
    overdue = overdue or []
    issue_total = (
        len(link_issues)
        + len(index_issues)
        + len(scan["missing_fm"])
        + len(scan["bad_type"])
        + len(scan["always_apply_not_indexed"])
        + len(structure["root_files"])
        + len(structure["missing_index"])
        + len(structure["uncovered"])
        + len(overdue)
    )
    health = "green" if issue_total == 0 else ("yellow" if issue_total < 20 else "red")

    report = [
        "---",
        "name: Memory health report",
        f"description: Auto-generated every 12 hours by launchd (ai.myproject.memory-health), mode={mode}",
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
        f"- **MEMORY.md bytes**: {MEMORY_INDEX.stat().st_size if MEMORY_INDEX.exists() else 0} (warn {MEMORY_BYTE_WARN}, ceiling {MEMORY_BYTE_ERR})",
        f"- **session_log.md lines**: {session_log_lines}",
        f"- **Files missing `scope:` frontmatter**: {scan.get('scope_missing', 0)} (backfill opportunistically on touch — informational, not counted as issues)",
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
        _format_section("Root-closed violations (new files at memory root)", structure["root_files"]),
        _format_section("Folders missing index.md", structure["missing_index"]),
        _format_section(
            "Files not linked from any index in their folder tree (structural coverage)",
            structure["uncovered"],
        ),
        _format_section("Overdue dated reminders", overdue),
        _format_section(
            "Transition stubs at root (informational, not issues)",
            structure["root_stubs"],
            empty_msg="none",
        ),
        "",
        "---",
        "",
        "_Launchd job: `ai.myproject.memory-health` (every 12h)._",
        f"_Run mode: `{mode}`. Run `python3 ~/.claude/hooks/ai_memory_health_audit.py` (no flag) for report-only dry runs._",
        "_Disable: `launchctl unload ~/Library/LaunchAgents/ai.myproject.memory-health.plist`_",
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
    ap = argparse.ArgumentParser(description="Memory health audit")
    ap.add_argument("--apply", action="store_true", help="apply safe mutations (default: report-only)")
    ap.add_argument("--strict", action="store_true", help="exit nonzero if any report-only issue is found")
    args = ap.parse_args()
    mode = "apply" if args.apply else "report-only"

    link_issues, index_issues, line_count = _check_index()
    index_paths = _index_referenced_paths()

    mutation_counts: dict | None = None
    if args.apply:
        mutation_counts = _apply_mutations(index_paths)
        # Re-read after mutations for accurate report
        link_issues, index_issues, line_count = _check_index()
        index_paths = _index_referenced_paths()

    scan = _scan_files(index_paths)
    structure = _check_structure()
    overdue = _check_overdue_reminders()
    sl_lines = _session_log_lines()
    issue_total = _write_report(
        mode, link_issues, index_issues, line_count, scan, sl_lines, mutation_counts,
        structure, overdue,
    )
    health = "green" if issue_total == 0 else ("yellow" if issue_total < 20 else "red")
    _append_session_breadcrumb(mode, health, issue_total, mutation_counts, scan["total"], line_count)
    if args.strict and issue_total > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
