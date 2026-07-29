---
name: ai-config-audit
description: Use when explicitly asked to audit or synchronize Claude and Codex rules, skills, hooks, plugins, credentials, or shared <project> memory.
disable-model-invocation: true
---

# AI Config Audit

## Overview

Run the audit script; do not recreate its checks ad hoc. It is report-only and
never emits credential values.

## Usage

```bash
# Human-readable audit; auto-detects a <project> worktree from $PWD
python3 ~/.claude/skills/ai-config-audit/scripts/audit.py

# Stable CI output
python3 ~/.claude/skills/ai-config-audit/scripts/audit.py --json

# Explicit checkout
python3 ~/.claude/skills/ai-config-audit/scripts/audit.py \
  --project-root /absolute/path/to/your-repo
```

Exit codes: `0` clean, `1` findings, `2` incomplete audit/configuration error.

## Output Contract

Findings contain only a rule ID, severity, path, line number, and safe
classification. Secret bytes, hashes, lengths, snippets, and subprocess output
are forbidden. In `--json` mode stdout is exactly one JSON document.

## Common Mistakes

- Run from the intended worktree or pass `--project-root`; otherwise the
  canonical checkout is audited.
- Fix Claude-owned sources, then run `sync-ai-config.py --write --scope global`
  or run `--write --scope project` from an isolated worktree; never edit a
  generated Codex instruction file directly.
- A plugin-managed skill is not a missing Claude-to-Codex symlink.
- `~/.codex/memory` is shared; `~/.codex/memories` must remain separate.
