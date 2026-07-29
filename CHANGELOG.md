# Changelog

## 2026-07-28 — the five-vendor rewrite

The first release described a 3-vendor gate and a voting-based planning model. Both changed. This release brings the repo back in sync with the setup it's documenting, and adds four subsystems that didn't exist before.

### Review panel: 3 vendors → 5

| | Then | Now |
|---|---|---|
| T1 planning | Claude + Codex | Claude + one OpenAI voice + Kimi + GLM |
| T2 post-impl | Claude + Codex | Claude + Codex + Kimi + GLM |
| T3 pre-commit | Claude + Codex + CodeRabbit | + Kimi + GLM (five) |

Panel history in full:

- **2026-05-15** — Gemini out (ungrounded `gemini -p` fabrications), CodeRabbit in.
- **2026-05-18** — Gemini re-introduced alongside CodeRabbit once a grounded CLI was verified (4 reviewers).
- **2026-05-28** — CodeRabbit rationed to T3 only (CLI credit caps).
- **2026-06-18** — Google killed the Gemini CLI for individual OAuth tiers.
- **2026-06-19** — Google leg migrated to Antigravity (`agy`, read-only).
- **2026-07-17** — **Gemini removed for good** after fabrications on 07-08 and 07-13. Kimi (Moonshot) took the slot. GLM (Zhipu) added as a 5th panelist the same day.
- **2026-07-18** — T1 reworked from voting to editorial harvest; ChatGPT added as a business-planning voice (same model as Codex — one OpenAI brain, planning only, never a reviewer).

Gemini's removal was about *fabrication*, not cost — so "it's free on Antigravity now" doesn't reverse it. It stays ad-hoc-only, with a sanctioned utility role (cheap batch LLM, cheap image generation) that never touches judgment.

### Planning: voting → editorial harvest

Voting optimizes for the median plan and deletes minority insight — which is frequently where the best idea is. Planning now has each voice write a fully independent plan; the host steelmans every one (including its own) and grafts the best pieces into a single coherent plan. Under harvesting, more voices is strictly better, so there's no longer any cost or task gating on who gets invited.

See [`docs/planning-by-harvest.md`](docs/planning-by-harvest.md).

### New: the shared contract

`rules/multi-ai-harness.md` (contract-id `multi-ai-harness-v2`) is loaded by **both** Claude and Codex and **overrides host-specific docs on conflict**. Panel facts — rosters, model IDs, waterfalls, permission matrix, quorum table — live there and nowhere else.

Facts duplicated across five host docs rot at five different rates. Centralizing them means procedure docs can go stale without becoming dangerous.

### New: implementation fallback protocol

`rules/opus-fallback-implementation.md` + `scripts/codex-implementation-fallback.sh`.

When the host model degrades (usage limits), it keeps orchestration, git, and review dispatch, and delegates *implementation* down a ladder: Codex `gpt-5.6-sol` → Kimi managed → Kimi paid API → Codex `gpt-5.5` → orchestrator-implements-and-reports.

Enforced invariants: worktree-only (refuses canonical), safe prompt passing from a file, a dispatch sentinel, a git-state guard that never auto-resets, and an engine report so review gates know who authored the diff. **Every rung change requires an untouched workspace** — partial edits stop the ladder rather than risk duplicated work.

Generalized the authored-diff rule: whichever engine wrote the diff reviews it advisory-only, excluded from convergence counts and failure math, with quorum recomputed from the remaining eligible panel.

See [`docs/implementation-fallback.md`](docs/implementation-fallback.md).

### New: config audit + one-way Codex sync

`skills/ai-config-audit/` runs 22 checks over rules, skills, hooks, plugins, credentials, and memory across both hosts. `scripts/sync-ai-config.py` generates Codex's `AGENTS.md` from Claude-owned sources, with a content digest so hand-edits are detectable.

🔴 **`0 findings; 0 failed checks` is also the output of an audit that silently didn't run.** That fail-open signature is real and it happened. Prove liveness with a planted canary before believing a green result.

See [`docs/config-audit-and-sync.md`](docs/config-audit-and-sync.md).

### New: Keychain credential broker

`scripts/keychain-exec.sh` fetches a secret from the macOS Keychain and injects it into a child process's environment, so `.mcp.json` holds a *service name* instead of a token. The credential mapping is allowlisted and the command is pinned per credential — a generic "fetch any key, run any command" tool would itself be an exfiltration primitive.

This landed because the audit's `security.config_files` check flagged a plaintext `export ZAI_API_KEY=` in `~/.zshrc`.

See [`docs/secrets.md`](docs/secrets.md).

### New: the wrappers themselves

`wrappers/` now ships the three read-only harnesses the reviewer agents call, rather than assuming they exist:

- **`kimi-review`** — runs Kimi in a disposable git worktree (isolation by *process*, not policy: `kimi --print` implicitly auto-approves all tool calls and has no read-only flag). Size-scaled timeouts (600/900/1200s) with slice-on-timeout recovery and a 1800s ceiling.
- **`glm-review`** — runs `claude` against z.ai's Anthropic-compatible endpoint on GLM weights; read-only via tool allowlist plus an external cwd so the target repo's own hooks never load.
- **`chatgpt-plan`** — business/strategy planning on the ChatGPT subscription backend rather than the separately-metered platform API.

### Fixed

- **`-p` + piped stdin silently discarded the pipe** in both `kimi-review` and `glm-review`. `git show X | kimi-review -p "review this"` returned a confident review of the repo at HEAD instead of commit X — the wrong code, no warning. Both now exit 2. They are mutually exclusive; embed the diff *in* the prompt.
- **`kimi-review` partial coverage reported as success.** Slicing that recovered only some slices exited 0. It now exits 65 with an explicit `COVERAGE: n of N` + `INCOMPLETE` banner. The first cut of this graded 1-of-4 slices as a complete review.
- **The 5-minute reviewer kill was aborting healthy reviews.** Measured: 10KB ≈ 4 min, 30KB ≈ 6.5 min, 74KB up to ~15 min. The wrappers self-bound; don't second-guess them.
- **CodeRabbit CLI 0.7.0 flag migration.** `--plain` removed (now the default; passing it errors), `-t/--type` is a hidden legacy selector that conflicts with `--committed`/`--uncommitted`, and **`--include-untracked` is now mandatory** for uncommitted scope — without it, brand-new files are silently dropped and the gate reports clean on an incomplete diff.
- **Worktree base moved off `/tmp/`.** macOS wipes `/tmp/` on reboot; that wipe destroyed uncommitted work in a live incident. Base is now `~/.agent-worktrees/`, overridable via `WORKTREE_BASE`. Legacy paths are still recognized for cleanup.
- **Documented the macOS TCC failure** that silently disables both launchd reapers when the repo lives under `~/Downloads`/`~/Documents`.
- **`audit.py` now fails loudly without a TOML parser** instead of raising `ModuleNotFoundError`. macOS system Python is 3.9, where `tomllib` isn't stdlib. Caught by testing the installer against a clean `HOME` rather than the author's machine.

### Changed

- `MEMORY.md` went from a flat index to a **three-tier router** (router → folder `index.md` → atomic note). The flat index stopped scaling around a few hundred notes — the index became the thing too big to load. The corpus is now 763 notes behind a ~200-line router.
- Memory and worktree hooks are **project-agnostic**: they derive paths from `AI_MEMORY_PROJECT_ROOT` / `AI_CANONICAL_REPO` instead of hardcoded absolutes.
- `install.sh` now installs `wrappers/`, `skills/`, and `ai-config/`, warns when `~/.local/bin` isn't on PATH, adopts the statusline only if you don't already have one, and preflights the TOML dependency. Verified idempotent against a throwaway `HOME`.
- `sanitize-check.sh` rewritten: 65 patterns, now including **credential-value patterns** for every vendor the pack talks to. Retailer patterns anchored so `Target:` as a label no longer false-positives.
- `upstream-skills.md` rewritten from the real install — 150 skills, and the note that **63 are explicitly disabled** via `skillOverrides`. Installed count is not active count.
- `superpowers` now installs from `claude-plugins-official` (v6.2.0), not `obra/superpowers` directly.

### Removed

- `docs/three-vendor-review-gate.md` → replaced by [`docs/review-panel.md`](docs/review-panel.md).

---

## 2026-05-18 — initial release

3-vendor adversarial review gate (Claude + Codex + CodeRabbit), file-based memory system, write-time injection guards, multi-session worktree harness.
