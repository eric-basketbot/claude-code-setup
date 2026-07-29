# Rules

Everything here loads **every session**. That's the whole point and also the whole cost — a rule you don't actually believe in is a permanent tax on tokens *and* on behavior. Read them, then delete the ones that don't fit your stack.

## The three tiers

### 1. The shared contract — `multi-ai-harness.md`

Loaded by **both** Claude and Codex, and it **overrides every other doc on conflict**. It holds *facts*: panel rosters per gate, model IDs and waterfalls, the permission matrix, the authored-diff quorum table, the hallucination policy.

Edit panel facts **here first**, then follow the churn checklist at the bottom of the file. Facts duplicated across five host docs rot at five different rates; centralizing them means procedure docs can go stale without becoming dangerous.

### 2. Harness rules

| File | What it governs |
|---|---|
| `codex-adversarial-review.md` | Claude's *orchestration procedure* for the three gates. The filename is retained for backward compatibility — it covers all five vendors, not just Codex. |
| `opus-fallback-implementation.md` | Who writes code when the host model degrades, and the engine ladder. |
| `agents.md` | Which subagent to reach for. Host-only — meaningless to another assistant. |
| `development-workflow.md` | Research-first → plan → TDD → review → commit. |
| `git-workflow.md` | Commit message format, PR workflow. |
| `performance.md` | Model selection, context-window management. |
| `hooks.md` | Hook conventions. Host-only. |

### 3. Stack opinions — **edit or delete these**

`coding-style.md`, `patterns.md`, `security.md`, `testing.md` are TypeScript/JS-flavored starter templates. They're here as a shape to copy, not a standard to adopt. If you write Go or Python, these are actively wrong for you.

## Shared vs. host-only

`ai-config/sync-manifest.json` splits rules into `global.rules` (shared with Codex) and `global.host_only_rules` (Claude only).

The distinction is worth getting right. A rule that says "dispatch the `codex-reviewer` agent" is meaningless to Codex — and worse, it invites Codex to try reviewing on Claude's behalf. The test:

- **Describes what is true about the system** → share it.
- **Describes how *this host* orchestrates** → host-only.

## The domain-rule pattern

The most valuable rule in the source setup isn't in this repo, because it's entirely project-specific. It's worth describing as a *pattern*.

It's a one-page standard for how the project handles geography: coordinates are the primary key for all location logic, postal codes are display-only, here are the correct and incorrect query shapes, and here's what every new data source must provide. It exists because the same class of bug kept recurring — someone filters by postal-code prefix, it looks right in testing, and it's subtly wrong at every boundary.

The generalizable shape:

> **When a domain concept has one correct representation and several tempting-but-wrong ones, write the standard down as a rule and include the wrong versions explicitly, marked wrong.**

Showing the anti-pattern next to the pattern matters more than it sounds. A rule that only shows the right answer doesn't stop someone reaching for the plausible wrong one, because they never recognize that's what they're doing.

Candidates in most codebases: money and rounding, time zones and timestamp storage, identity and tenancy scoping, units and conversions, pagination and ordering stability, soft-delete semantics.

Keep these project-scoped (`<repo>/CLAUDE.md` or a project rules dir), not global. A geography standard from one project misfiring in another is exactly the contamination the project/global split exists to prevent.
