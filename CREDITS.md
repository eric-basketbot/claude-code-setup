# Credits

This repo packages original rules + hooks + scripts. It builds on, integrates with, or references several upstream projects — all of which retain their own licenses and authorship.

## Upstream projects referenced (not redistributed)

- **Claude Code** — Anthropic's official CLI. Required base. https://claude.com/claude-code
- **codex CLI** — OpenAI's coding agent CLI. The `codex-reviewer` agent wraps `codex exec review`. https://github.com/openai/codex
- **CodeRabbit CLI** — purpose-built code review CLI. The `coderabbit-reviewer` agent wraps `coderabbit review`. https://www.coderabbit.ai
- **Everything Claude Code (ECC)** — a marketplace of skills referenced from this setup but not redistributed. See [`upstream-skills.md`](upstream-skills.md) for the install commands.
- **gstack** — headless-browser QA skill referenced by some rules. https://gstack.dev or per its current upstream.
- **gsd-build / get-shit-done** — the original prompt-injection scanners (`gsd-read-injection-scanner.js`) were the starting point for the `cc-*-injection-*.js` hooks. The hooks here are adapted from that work and remain MIT-licensed.
- **obra/superpowers** — patterns inspired by; see the upstream-skills manifest for which skills came from there.
- **bencium plugins** — additional design + UX skills referenced from there.
- **plankton** — write-time formatter/linter pattern; the `plankton-code-quality` skill is upstream.
- **hookify** — the user-facing hook configuration plugin; referenced in `settings.json` but not redistributed here.

## What's original in this repo

- The 3-vendor adversarial-review rule (`rules/codex-adversarial-review.md`) and its operationalization across planning / post-implementation / pre-commit gates.
- The file-based memory architecture (atomic notes, frontmatter conventions, lifecycle hook) under `hooks/memory_health_audit.py` and `memory-system/`.
- The session-snapshot + pre-compact breadcrumb hooks (`hooks/session_snapshot.py`, `hooks/precompact_session_log.py`).
- The `codex-reviewer` and `coderabbit-reviewer` orchestration agents.
- The multi-session worktree harness under `project-overlay/multi-session-worktrees/`.
- The installer (`install.sh`, `install-in-project.sh`), sanitize gate, settings merger.
- The cross-vendor review aggregator (`scripts/cross-ai-review.sh`).

## Anti-redistribution policy

If you derive from this repo and add new skills/rules/hooks, attribute responsibly. If you pull upstream skills (ECC, obra, bencium, etc.) into your own bundle, follow each upstream's license and attribution requirements — don't claim them as part of this setup.
