# Memory system architecture

A file-based, atomic-note memory layer for Claude Code that survives across sessions, gets curated automatically, and stays under the auto-load cap. The full operational docs are in [`../memory-system/README.md`](../memory-system/README.md). This doc is the architecture explainer.

## The problem with default Claude memory

Claude Code's built-in memory is a single `MEMORY.md` file under `~/.claude/projects/<slug>/memory/`. It works, but as the project ages:

- The file grows past the auto-load token cap.
- It becomes a flat dumping ground with no structure.
- Old facts that are no longer true sit alongside current ones.
- There's no lifecycle — nothing trims, rotates, or quarantines stale entries.
- Cross-session recall is fragile because there's no checkpoint anchor when context gets compacted mid-session.

## The architecture here

Four pieces that turn the default into a curated knowledge graph:

### 1. Atomic notes in topical folders

One fact per file. Each file has frontmatter:

```
---
name: <short title>
description: <one-line description — used when Claude looks for memories>
type: <user | feedback | project | reference>
scope: <always-apply | on-demand>      # optional
---
```

Folders correspond to topic areas (`user/`, `feedback/`, `project/`, `infrastructure/`, `frontend/`, `testing/`, `security/`, `reference/`, `completed/`). `meta/` is reserved for the audit hook's reports and session logs.

The four types are intentionally narrow:
- `user`: facts about YOU (preferences, role, expertise)
- `feedback`: corrections AND validated approaches. Body leads with the rule, then `**Why:**` + `**How to apply:**` lines.
- `project`: ongoing work, decisions, deadlines. Include absolute dates.
- `reference`: pointers to external systems (dashboards, channels, tools).

### 2. `MEMORY.md` is an index, not a memory

The only file auto-loaded each session. Keep it under 200 lines (the cap). Each entry is one line: `- [Title](path/to/note.md) — one-line hook`. The atomic notes live in subdirs and only get pulled in when relevant.

This keeps token cost flat as the corpus grows — adding 100 new notes doesn't increase what loads on session start, only `MEMORY.md` does.

### 3. Lifecycle hook (`memory_health_audit.py`)

A launchd job runs every 12 hours. Two modes:

- **Report-only** (no flag): walks the memory dir, writes a health report to `meta/memory_health_report.md`. Never mutates.
- **Apply mode** (`--apply`): runs four safe mutations under a mutation cap:
  1. Quarantine stale files (365+ days old, not protected, not in the index) into `memory-repository/<today>/archived/`.
  2. Rotate `meta/session_log.md` if >500 lines (keeps last 100, archives the rest).
  3. Quarantine session snapshots older than 60 days.
  4. Permanently delete entries from `memory-repository/` older than 180 days.

Protected dirs (`user/`, `meta/`, `completed/`) are never auto-quarantined. Files marked `scope: always-apply` are never auto-quarantined.

Every mutation goes through `memory-repository/` first — files leave `memory/` only by passing through quarantine. Hard cap of 50 mutations per run; if the audit wants to exceed it, it halts and reports instead.

Idempotent. Running twice is a no-op.

### 4. Capture hooks for cross-session continuity

Two write hooks complete the architecture:

- **`session_snapshot.py`** (UserPromptSubmit): every 15 minutes of active use, dumps the last ~40 user+assistant text messages into `meta/session_snapshots/<date>_<session-id>.md`. Captures what you were actually working on.
- **`precompact_session_log.py`** (PreCompact): single-line breadcrumb to `meta/session_log.md` every time context gets compacted, with session ID, trigger, and first-user-message preview.

The snapshots survive the compaction. When you resume work tomorrow, the audit hook reports the snapshot is there, you can read it back, and you're not relying on the model's compressed memory.

## Comparison to alternatives

vs. **default Claude memory**: same storage mechanism (still `~/.claude/projects/<slug>/memory/`), just structured around an index + atomic notes + lifecycle hook. You can fall back to flat MEMORY.md any time — the audit hook just won't have much to do.

vs. **mem-palace-style structured memory**: similar atomic-note idea but file-based, not vector-DB-backed. No semantic search; you rely on Claude reading the index and pulling files by name/path. Tradeoff: no semantic recall, but full transparency, no embedding cost, no extra service to run, and you can grep your memory like any text corpus.

vs. **Anthropic's emerging memory features (2026+)**: those handle session continuity at the framework layer. This setup is complementary — the framework gets continuity across N turns; this setup gets continuity across N *days*, plus structured curation.

## What goes in / what doesn't

**Save:**
- Things Claude couldn't derive from the codebase (preferences, prior incidents, the *why* behind a decision)
- External-system pointers (dashboards, channels, tools)
- Corrections (what NOT to do) AND validated approaches (what surprisingly worked)
- Project decisions with absolute dates

**Don't save:**
- Code patterns derivable from reading the repo
- Git history (`git blame` is authoritative)
- Debugging recipes (the fix is in the commit message)
- Ephemeral task state — use TodoWrite for that
- Anything in CLAUDE.md (it's already auto-loaded by Claude Code)

## Recovery

Quarantined files live in `<project>/memory-repository/<date>/` for 180 days before final deletion. Recover with:

```bash
cp -R ~/.claude/projects/<slug>/memory-repository/<date>/archived/<path> \
      ~/.claude/projects/<slug>/memory/<path>
```

## Disabling

The audit hook is launchd-driven. Disable with:

```bash
launchctl unload ~/Library/LaunchAgents/com.example.claude-memory-health.plist
```

The capture hooks (snapshot + precompact) are wired through `~/.claude/settings.json`. To disable, edit settings.json and remove the relevant entries — or just delete the hooks themselves and let the harness no-op on missing files.

You can still run the audit manually any time:

```bash
python3 ~/.claude/hooks/memory_health_audit.py            # report-only
python3 ~/.claude/hooks/memory_health_audit.py --apply    # apply mutations
```
