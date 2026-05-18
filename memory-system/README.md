# Memory system

A file-based persistent memory for Claude Code that survives across sessions, gets curated automatically, and stays under the auto-load cap. Built around Claude Code's built-in `~/.claude/projects/<slug>/memory/MEMORY.md` mechanism but with structure and a lifecycle hook on top.

## Why this exists

Claude Code's default memory is a flat file you grow until it's too big. This setup adds:

1. **Atomic notes**: one fact per file, organized by topic folder. No giant rolling logs.
2. **An index** (`MEMORY.md`) that's the only thing auto-loaded — keeps token cost flat as the corpus grows.
3. **A lifecycle hook** (`memory_health_audit.py`) that:
   - Quarantines stale files (365+ days, not protected, not in the index)
   - Rotates the session log when it exceeds 500 lines
   - Quarantines old session snapshots (60+ days)
   - Permanently deletes quarantined files after 180 days
   - Reports broken links + missing frontmatter every run
4. **Two write hooks** (`session_snapshot.py`, `precompact_session_log.py`) that capture session state automatically so cross-session recall survives context compaction.

## Files in this directory

- `memory-tree.txt` — the recommended layout (folders + what each holds)
- `MEMORY.md.template` — the index file that gets auto-loaded each session
- (The actual hooks are in `../hooks/`)

## How install.sh wires it up

`./install.sh` (top-level) does this for you:

1. Detects the project you point it at (or auto-picks the most-recent project under `~/.claude/projects/`).
2. Creates the directory skeleton from `memory-tree.txt`.
3. Copies `MEMORY.md.template` → `<project>/memory/MEMORY.md` (only if not already present — doesn't clobber existing memory).
4. Installs the lifecycle + capture hooks into `~/.claude/hooks/`.
5. Wires the hooks into `~/.claude/settings.json` via the fragment.
6. Optionally installs a launchd plist (macOS) to run the audit every 12 hours.

## Frontmatter conventions

Every atomic note carries:

```
---
name: <short title>
description: <one line — used to decide relevance when Claude looks for memories>
type: <user | feedback | project | reference>
scope: <always-apply | on-demand>     # optional
---
```

- `type: user` — facts about you (role, preferences, expertise)
- `type: feedback` — corrections or validated approaches. Body should lead with the rule, then `**Why:**` + `**How to apply:**` lines.
- `type: project` — work-in-flight, decisions, deadlines. Include absolute dates.
- `type: reference` — pointers to external systems (dashboards, channels, tools)
- `scope: always-apply` — file is critical enough to load every session. Must be referenced in `MEMORY.md`.

The audit hook surfaces:
- Files with missing/invalid frontmatter
- Files marked `always-apply` but not in `MEMORY.md` (drift signal)
- Broken links inside `MEMORY.md`

## What goes in vs. what doesn't

**Save:**
- Things Claude couldn't derive from the codebase (preferences, prior incidents, the *why* behind a decision)
- External-system pointers
- Corrections (what NOT to do) AND validated approaches (what surprisingly worked)

**Don't save:**
- Code patterns derivable from reading the repo
- Git history (`git blame` is authoritative)
- Debugging recipes (the fix is in the commit)
- Ephemeral task state — that's what TodoWrite is for

## Recovery

Quarantined files live in `<project>/memory-repository/<date>/` for 180 days before final deletion. Recover with:

```bash
cp -R ~/.claude/projects/<slug>/memory-repository/<date>/archived/<path> \
      ~/.claude/projects/<slug>/memory/<path>
```

## Disabling the lifecycle

If you don't want auto-quarantining:

```bash
launchctl unload ~/Library/LaunchAgents/com.example.claude-memory-health.plist
```

You can still run the audit manually for a report any time:

```bash
python3 ~/.claude/hooks/memory_health_audit.py            # report-only
python3 ~/.claude/hooks/memory_health_audit.py --apply    # apply mutations
```
