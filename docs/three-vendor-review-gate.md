# The 3-vendor adversarial review gate

The flagship piece of this setup. Forces every non-trivial change through three independent review harnesses — Claude, Codex (OpenAI), and CodeRabbit — at three checkpoints. The full spec is in [`rules/codex-adversarial-review.md`](../rules/codex-adversarial-review.md). This doc is the explainer.

## Why three reviewers, not one or two

Single-model review has a blind-spot problem: a model reviewing its own work shares its own assumptions. Two-model review surfaces some disagreements but can still miss bugs both models share training-corpus blind spots on.

The real signal comes from **harness diversity**, not just vendor diversity:

- **Claude (Anthropic, general harness):** the primary planner + executor. Smart, but works inside the same conversation as the implementation.
- **Codex (OpenAI, agentic review harness):** different vendor. Tooled to explore the repo agentically during review. Best at catching architecture-level issues that fly under Claude's nose.
- **CodeRabbit (Anthropic-based, but a purpose-built review pipeline):** server-side AST + lint + dep-graph + repo-context grounding. Best at catching concrete code-level bugs because findings are anchored to actual symbols/lines in the repo.

The harness difference (agentic vs. grounded vs. conversational) catches more than vendor difference alone would.

> **Historical note**: an earlier version of this gate used Gemini as the third reviewer. Removed because the Gemini CLI's review mode had no file access during review — findings were generated from the diff text only, leading to hallucinated symbols/files. CodeRabbit replaced it because its server-side harness grounds every finding in actual repo state.

## The three triggers

### Trigger 1 — Parallel planning (before code)

When you ask for a non-trivial change, Claude does NOT propose a plan first. Instead, it dispatches Codex and CodeRabbit in parallel with the **raw user prompt** (no paraphrasing), while forming its own plan independently. Three plans come back, get diffed on three axes (approach, files, sequencing):

- All three agree → unified plan presented, with a "Codex AND CodeRabbit independently proposed the same approach as me" line so you know consensus was reached.
- 2-of-3 majority → majority plan presented + dissenter surfaced explicitly with the core tradeoff and what the dissenter might be seeing.
- 3-way split → one round of cross-critique (each tool sees the other two plans); if they converge, present merged plan.
- Still split → escalate to you via `AskUserQuestion` with each option side-by-side. Your call is final and gets recorded.

Cost: 1–3 min wall time (parallel calls).

### Trigger 2 — Post-implementation review (after code, before tests)

The moment Claude believes implementation is complete, BEFORE running the test suite. Both reviewers run in parallel with uncommitted scope, focused on the four concerns:

- **Implementation bugs** (logic errors, off-by-one, swapped args)
- **Missed edge cases** (nulls, unicode, concurrency, partial failure, idempotency)
- **Migration hazards** (schema changes that lock hot tables, irreversible drops)
- **Test gaps** (new paths without tests, mocked-where-real-needed)

Why before tests? Because test gaps surfaced here can be filled in the same pass. Running tests first means either re-running them (wasteful) or shipping with the gap (defeats the purpose).

### Trigger 3 — Pre-commit (the final diff)

After tests pass and before `git commit`. Both reviewers run again on the exact diff that's about to land. Two-harness sanity check on the final shape.

This fires for **every** commit. The cost (1–4 min, parallel) is the price of the safety net.

## On findings — the hard gate

When findings come back, they're surfaced verbatim, grouped by reviewer (`## Codex Review` then `## CodeRabbit Review`). Convergence (both reviewers flag the same line) is marked **HIGH-CONFIDENCE**. Divergence (only one flags) is shown with the reviewer name; you decide if it's a real edge case the other missed or a false positive.

Claude STOPS. No commit, no push. Waits for you. You decide: fix, override, or ship as-is. If you override, the override is recorded in the commit body so it's auditable.

## Hallucination tracking

The rule includes a session-scoped counter at `/tmp/reviewer-hallucinations-<worktree>.log` that logs verified hallucinations per reviewer. The trigger: if a reviewer hits ≥2 verified hallucinations in a session (cited symbol/file/migration doesn't exist OR cited behavior is the literal opposite of reality), it gets benched for the rest of the session and the gate runs with the other reviewer alone. Per-session, per-worktree — fresh sessions get a clean counter.

This is the safety valve. A normally-grounded reviewer can drift on a particular diff shape; the counter catches the streak without permanently blacklisting a vendor.

## What it costs

- **Time**: 1–4 minutes per gate, parallel. Three gates per non-trivial change = ~5–12 min added overhead.
- **Money**: depends on your Codex plan + CodeRabbit tier. Personal repos can use CodeRabbit's free tier; org repos need a paid CodeRabbit plan. Codex bills against your OpenAI plan.

The trade is: pay 5–12 min of latency, get a documented cross-harness signal on architecture AND implementation AND final diff. In practice, the catches are concentrated in cases where one reviewer surfaces an issue that the others missed — exactly the cases you couldn't have caught with single-model review.

## Skipping the gate

The gate fires ONLY on non-trivial changes. Trivial = ANY of:
- Typo / single-line / rename / comment / formatting
- Config-only edits (no logic changes)
- Test-only edits (no production code touched)

Non-trivial = ANY of:
- >1 file touched
- >3 steps
- Schema migrations, auth changes, data flow, external API contracts
- Payment, billing, PII
- A high-risk path you define for your own project (e.g., `scraper/**`, `migrations/**`)

Conflicts resolve toward non-trivial. Test edits in a high-risk directory still run the gate.

## Failure modes

- **One reviewer auth fails**: gate is PARTIALLY MET. You decide whether to retry, proceed with one-harness coverage, or fix auth and re-run. Default: ask you. Never silently degrade.
- **Both reviewers fail**: stop. No shipping without any review. Fix at least one, then re-run.
- **Reviewer hangs >5 min**: kill it, ask you whether to retry or skip.
- **Diff too large for CodeRabbit**: split by directory or by commit, re-run.
- **No diff to review**: skip silently, proceed.

## When to use it vs. when not

Use it as the default operating posture for any production codebase you ship. Skip it for one-off scripts, throwaway experiments, learning projects where the cost overhead outweighs the benefit. The gate is loud — it makes you stop and read findings — that's the point, but it's not free.
