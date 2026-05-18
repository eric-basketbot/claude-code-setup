# Cross-Vendor Adversarial Review (Codex + CodeRabbit)

> A two-reviewer adversarial panel: **Codex (OpenAI)** at `/usr/local/bin/codex` and **CodeRabbit** at `/opt/homebrew/bin/coderabbit` (purpose-built review CLI, Anthropic-based models with a server-side AST + lint + repo-context harness). Three independent perspectives — Claude (Anthropic, general harness), Codex (OpenAI, agentic review harness), CodeRabbit (Anthropic, purpose-built review harness) — plan together, review together, and gate together.

> **One-time install precondition (per-repo):** CodeRabbit requires its GitHub App to be installed on the repo's GitHub org/account before `coderabbit review` will work. CLI auth (`coderabbit auth login`) is NOT enough. Install at https://github.com/apps/coderabbitai → select your org → grant access to the specific repo. If `coderabbit review --plain --type uncommitted` returns "CodeRabbit could not connect this repository to a CodeRabbit organization," the install is missing. Until installed, the panel degrades to Codex-only — surface this to the user before running the gate.

**Why this isn't a Gemini panel.** An earlier version of this rule used Gemini as the third reviewer. The `gemini -p` harness has no file access during review — findings are generated from the diff text alone, which led to repeated hallucinations of symbols/files that don't exist. CodeRabbit replaced it because its server-side harness grounds findings in the actual repo (AST + lint + dep-graph). Gemini can still be useful for cheap-batch tasks (translation, classification) but is not in the active review rotation.

CodeRabbit being Anthropic-based means cross-vendor diversity is weaker than Anthropic+OpenAI+Google would be. The harness difference (purpose-built review pipeline vs. general-purpose chat) closes most of the gap; the residual loss is the narrow class of bugs that come from shared training-corpus blind spots between Claude and CodeRabbit. Codex remains the cross-vendor leg of the panel.

Each reviewer is invoked via its dedicated agent so findings come back unfiltered:

- **`codex-reviewer` agent** (`~/.claude/agents/codex-reviewer.md`) — wraps `codex exec review` with `--base`, `--uncommitted`, `--commit` scoping. Agentic — Codex reads surrounding files during review.
- **`coderabbit-reviewer` agent** (`~/.claude/agents/coderabbit-reviewer.md`) — wraps `coderabbit review --plain` with `--type`, `--base`, `--base-commit` scoping. Server-side harness — AST + lint + repo context grounds every finding.
- **`codex exec --full-auto "<prompt>"`** — fire-and-forget planning. Codex explores the repo, produces a plan.
- **`~/.claude/scripts/cross-ai-review.sh`** — manual aggregator that runs every available AI CLI (codex, coderabbit, optionally claude/qwen) against the same diff. Use for ad-hoc review outside the trigger gates.

## What counts as non-trivial

These rules fire ONLY for non-trivial requests. Non-trivial = ANY of:
- Touches more than one file
- More than three steps
- Schema migrations, auth changes, data flow, or external API contracts
- Logic that writes to production data
- Payment, billing, or PII handling
- Any change to a high-risk area your project defines (add your own `<your-sensitive-paths>/**` rule here)

Trivial fixes skip both gates — just do the work:
- Typo, single-line change, rename, comment, formatting
- **Config-only edits** (changes confined to config files: `*.json`, `*.yaml`, `*.toml`, `.env*`, `config/**`, with no logic changes)
- **Test-only edits** (changes confined to test files: `*.test.*`, `*.spec.*`, `tests/**`, `__tests__/**`, with no production code touched)

Conflicts resolve toward non-trivial: a test edit in a sensitive directory still runs the gate. A config edit that also touches a `.ts` file is no longer config-only.

## Trigger 1: Parallel planning (consensus before work starts)

For non-trivial requests, planning runs in parallel — Claude does NOT present a plan first and let the others critique it. All three perspectives form independently from the user's literal prompt.

### Step 1 — dispatch Codex AND CodeRabbit with the user's verbatim prompt (in parallel)

Send the same raw user prompt to both, in a single message with two parallel tool calls. CodeRabbit's CLI is review-focused — for planning, run it in `--prompt-only` mode against the relevant files (or use its agent guidance output as a planning aid). Codex handles open-ended planning natively.

```bash
codex exec --full-auto "<user's request, copy-pasted, no rewording>"
coderabbit review --plain --prompt-only --type uncommitted -c <(echo "<user's request, copy-pasted, no rewording> — propose a step-by-step implementation plan with file paths, sequencing, and risks. Do not just review existing changes; propose what to add.")
```

Send the raw user prompt to both — do NOT paraphrase, do NOT add Claude's interpretation. Each must form its plan independently. Codex has `--full-auto` so it can read files and inspect the repo; CodeRabbit's `--prompt-only` returns its analysis as an agent prompt that includes its repo understanding.

If CodeRabbit's planning mode isn't producing useful plan output (it's optimized for review, not generation), fall back to Codex-only planning and rely on the dual review at Triggers 2/3 for the cross-harness signal. Note this in the user-facing summary.

If the user's prompt depends on prior conversation context the others won't have (e.g., "now do the same for X"), prepend the minimum context needed to make the request standalone, then send. Mark what you added.

### Step 2 — form Claude's plan in parallel

While Codex (1–3 min) and CodeRabbit (~1–2 min) run, form Claude's own plan using normal process. Don't wait idle — use the latency.

### Step 3 — compare three plans

When both return, diff all three on three axes:
- **Approach**: same overall strategy?
- **Files touched**: same set?
- **Sequencing**: same order, same dependencies?

### Step 4a — all three aligned

If all three plans agree on approach, files, and sequencing (minor wording differences are fine): present a single unified plan. State **"Codex AND CodeRabbit independently proposed the same approach as me"** so the user knows two-harness consensus was reached. Proceed when the user approves.

### Step 4b — 2-of-3 majority, one outlier

If exactly one of the three plans diverges on approach, files, or sequencing: present the majority plan AND surface the dissenter explicitly:

- **Majority plan** (Claude + [Codex or CodeRabbit]): one-line summary
- **Dissenting plan** ([the outlier]): one-line summary
- **Where they disagree**: one sentence on the core tradeoff
- **Why the dissent might still matter**: one sentence on what the outlier might be seeing that the majority missed

Default to the majority plan unless the user picks the dissenter. Record both in the commit message body if the dissent raised a non-trivial concern.

### Step 4c — three-way disagreement → one round of mutual critique

If all three differ on approach, run ONE round of cross-critique:

1. Claude reads Codex's and CodeRabbit's plans, notes specifically what it would change in each and why.
2. Send each tool the other two plans for critique (in parallel):
   ```bash
   codex exec --full-auto "Two alternate plans for the same request: <claude's plan> AND <coderabbit's plan>. Compare to your earlier plan. Identify what's better in each, what's worse, and propose the merged best plan."
   coderabbit review --plain --prompt-only --type uncommitted -c <(echo "Two alternate plans for the same request: <claude's plan> AND <codex's plan>. Compare to your earlier plan. Identify what's better in each, what's worse, and propose the merged best plan.")
   ```
3. If post-critique they converge: present the merged plan, note the convergence path.

### Step 4d — still split → user tiebreaks

If after one critique round the three still disagree on the core approach, escalate to the user via `AskUserQuestion` with each option side-by-side (use the `preview` field for the actual plan text). Frame it:

- **Claude's plan**: one-line summary
- **Codex's plan**: one-line summary
- **CodeRabbit's plan**: one-line summary
- **The disagreement**: one sentence on the core tradeoff (e.g., "Claude favors a runtime check; Codex favors a schema constraint; CodeRabbit favors splitting into two phases")

User picks one, picks a fourth option, or redirects. Their call is final. Record their choice in the eventual commit body so the override is auditable.

### Cost

Parallel planning adds 1–3 minutes per non-trivial request (parallel calls; wall time = slower of the two). The cost buys: catching blind spots Claude shares with itself, plus a documented cross-harness agreement signal before code is written. Don't skip the gate to save time.

**Dollar cost:** Codex bills against your existing OpenAI plan. CodeRabbit billing depends on your plan (free tier for personal repos, paid for org repos). Net new spend per gate ≈ Codex's per-call price + CodeRabbit's per-review price (if on a paid tier).

## Trigger 2: After implementation completes (post-implementation review)

For non-trivial work, run an adversarial review the moment implementation is "done" — before running the test suite, before staging, before any commit prep. Early planning review catches bad architecture. This late review catches what planning can't see: implementation bugs, missed edge cases, migration hazards, and test gaps.

The point of running this BEFORE tests (not after) is that test gaps surfaced here can be filled in the same pass — you write the missing tests, then run the suite once with full coverage. Running tests first and the review second means you either re-run the suite (wasteful) or ship with the gap (defeats the purpose).

### How to invoke

Invoke BOTH the `codex-reviewer` AND `coderabbit-reviewer` agents in parallel — single message, two `Agent` tool calls — with uncommitted scope and explicit focus on the four post-implementation concerns:

- **Implementation bugs**: logic errors, off-by-one, wrong operator, swapped arguments, broken control flow
- **Missed edge cases**: nulls/empties, unicode, timezone, concurrency, partial failure, retry semantics, idempotency
- **Migration hazards**: schema changes that lock hot tables, backfills that don't tolerate concurrent writes, irreversible drops, FK CASCADE blast radius, data loss on rollback
- **Test gaps**: new code paths without tests, modified branches without coverage, integration seams without fixtures, mocked-where-real-needed

Tell each reviewer these four are the focus — don't let them spend their budget on style nits.

### Order in the post-implementation flow

1. Implementation done (Claude believes work is complete)
2. **Post-implementation review (this trigger)** ← Codex + CodeRabbit run in parallel; surfaces bugs/edge-cases/migration risks/test gaps
3. User decides: fix findings (from either reviewer), add tests, override, or proceed
4. After fixes: pre-commit test suite (your project's test runner — unit + integration + e2e if applicable)
5. Pre-commit review (Trigger 3, on the final diff)
6. `git commit`

Same hard-gate semantics as planning: surface findings verbatim from both reviewers, stop, wait for user.

### When to skip

- Trivial fixes (per the "What counts as non-trivial" section above)
- Implementation made zero behavior changes (pure rename, formatting, comment-only)
- The diff at this stage is identical to what the pre-commit gate (Trigger 3) will see AND there are no test gaps to address — in that case running both is redundant and you can collapse to just Trigger 3. Default to running both unless you're sure.

## Trigger 3: Before every `git commit`

After tests pass and before `git commit`, invoke BOTH the `codex-reviewer` AND `coderabbit-reviewer` agents in parallel with uncommitted scope. This is the final pre-commit adversarial gate — a two-harness sanity check on the exact diff that's about to land.

This fires for every commit, including on feature branches and worktrees. The cost (1–4 min, parallel) is the price of the safety net.

The pre-commit test suite and the cross-harness review run in this order: tests first (cheap, fast-fail), then both reviewers in parallel (slow, deep). Don't run reviewers if tests are red.

Trigger 2 vs Trigger 3: Trigger 2 is broad ("does this implementation hold up?"), Trigger 3 is narrow ("is this exact diff safe to land?"). Trigger 2 may surface issues whose fixes change the diff; Trigger 3 reviews the final shape after those fixes settle. Skipping Trigger 2 lets bugs survive until Trigger 3, where the cost of fixing them (re-running the test suite) is higher.

## On findings (hard gate)

When Codex and/or CodeRabbit return findings:

1. Surface them VERBATIM to the user, **grouped by reviewer** (`## Codex Review` heading then `## CodeRabbit Review` heading). Don't summarize, don't filter, don't downgrade severity.
2. **Highlight convergence**: if both reviewers flag the same line/concern, mark it **HIGH-CONFIDENCE** at the top of the report — that's a finding two independent review harnesses agreed on.
3. **Note divergence**: if only one flags an issue, present it as-is with reviewer name. The user decides if it's a real edge case the other missed or a false positive.
4. STOP. Do not proceed with the plan, do not run `git commit`, do not push.
5. Wait for the user to decide: fix, override, or ship as-is.

The user makes the call on every finding. Claude does not autonomously override either reviewer's objections, even on issues that look minor or look like false positives. If a reviewer flags it, the user sees it and decides.

If the user says "ignore that finding" or "ship anyway", proceed — but record the override in the commit message body so it's auditable, and note which reviewer's finding was overridden.

## Failure modes

- **Codex auth fails** (`codex login` needed or `OPENAI_API_KEY` missing): surface the exact error, do not bypass the gate. Tell the user to run `codex login`.
- **CodeRabbit auth fails** (`coderabbit auth status --agent` returns `authenticated:false`): surface the exact error, do not bypass the gate. Tell the user to run `coderabbit auth login`. Do not silently fall through to another reviewer.
- **One reviewer fails, the other succeeds**: present the working reviewer's findings AND surface the failure of the other. Treat the gate as PARTIALLY MET — the user can decide whether to retry the failed reviewer, proceed with one-harness coverage, or fix the auth and re-run. Default: ask the user. Do not silently degrade the gate.
- **Both reviewers fail simultaneously**: stop. Without any review, no shipping. Surface both errors and have the user fix at least one before proceeding.
- **Reviewer hangs >5 min**: kill the process, surface the timeout, ask the user whether to retry or skip that reviewer (skipping requires explicit user instruction).
- **No diff to review** (uncommitted scope returns nothing): skip silently, proceed to commit.
- **CodeRabbit diff-too-large**: split by directory (`--dir`) or by commit (`--base-commit`) and re-run. Don't drop coverage.

## Hallucination tracking (applies to all reviewers)

A "hallucinated" finding is a reviewer claim that does not survive a 5-second grep/Read against the cited file/symbol/line. Wrong line numbers off by ≤3, slightly mis-named symbols that resolve unambiguously, or "missing test" findings whose tested-state you can't confirm in the diff alone do NOT count — only verifiable fabrications (cited symbol/file/migration does not exist, cited behavior is the literal opposite of what the code does).

CodeRabbit's grounded harness should drastically reduce fabrication rate vs. a no-context reviewer, but the counter remains in place because no harness is perfect.

### The verify step is mandatory

Before applying ANY reviewer fix or surfacing a finding as a blocker:

1. Grep for the cited symbol in the cited file.
2. Read the cited line range.
3. If symbol/line don't exist OR the finding describes code behavior that is contradicted by what's actually on disk: mark it **HALLUCINATED** in your write-up to the user, and append it to the session counter (next section).

### Session counter

Path: `/tmp/reviewer-hallucinations-$(basename "$(git rev-parse --show-toplevel)").log`

Format: one TSV line per verified hallucination —
```
<iso-timestamp>\t<model>\t<short-finding-summary>\t<why-it-was-hallucinated>
```

Append via:
```bash
LOG="/tmp/reviewer-hallucinations-$(basename "$(git rev-parse --show-toplevel)").log"
printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "coderabbit" "claimed connection leak in <function>" "code closes conn in try/finally at line 142" >> "$LOG"
```

Models tracked: any reviewer in the rotation — `codex`, `coderabbit`, future additions.

### Threshold → benched for the session

**Trigger**: a single model has ≥2 verified hallucinations in the current session's counter (one log file per worktree). Check the counter before every codex-reviewer / coderabbit-reviewer invocation:

```bash
LOG="/tmp/reviewer-hallucinations-$(basename "$(git rev-parse --show-toplevel)").log"
codex_count=$(grep -c $'\tcodex\t' "$LOG" 2>/dev/null || echo 0)
coderabbit_count=$(grep -c $'\tcoderabbit\t' "$LOG" 2>/dev/null || echo 0)
```

**If `codex_count >= 2`**: skip the codex-reviewer agent for the rest of the session. Run coderabbit-reviewer alone and note the gate is operating with one harness. Tell the user once: "Codex hit 2 verified hallucinations this session — running CodeRabbit alone for remaining reviews."

**If `coderabbit_count >= 2`**: same logic, skip coderabbit-reviewer for the session and run codex-reviewer alone. Tell the user once with the equivalent message.

**If BOTH `codex_count >= 2` AND `coderabbit_count >= 2`**: stop. The panel is broken. Surface the counter contents to the user and have them tiebreak — proceed with Claude only, retry the failed reviewer with a smaller diff scope, or skip the gate with an explicit override recorded in the commit body.

### Counter scope & lifecycle

- **Scope is per-worktree, per-session.** The `basename "$(git rev-parse --show-toplevel)"` keys the log to the worktree directory. Cleanup hooks remove worktrees → counter file disappears with them.
- **No carry-over across sessions.** A fresh Claude session sees an empty counter — past hallucinations don't permanently bench a model. The point is to catch a streak within one session, not to maintain a vendor blacklist.
- **No carry-over across worktrees.** Two parallel sessions each track their own counter; one session's bad run doesn't poison the other's.
- **Manual reset**: `rm /tmp/reviewer-hallucinations-*.log` if you want a clean slate mid-session (rare — only after a session-wide retry/redo).

### Why not a persistent rolling log

A 7-day rolling log was considered. Rejected because (a) hallucination rate varies wildly by diff shape — a model that drifted on one prompt may be fine on the next, and a persistent log would penalize the wrong dimension; (b) the "always grep-verify" rule already catches the worst pattern; (c) per-session reset keeps the panel honest by default — a bad run doesn't carry forward.

If a vendor turns out to be persistently bad across many sessions, that's a signal to flip the rotation — edit this rule, don't accumulate it in a log.

## Why

Single-model planning has a known blind-spot problem: a model reviewing its own work shares its own assumptions. Two-model consensus would surface some disagreements, but two models trained on overlapping data still share many assumptions.

The strongest review signal comes from **harness diversity, not just vendor diversity** — most bugs Codex catches that Claude misses come from Codex's review-tuned harness exploring the repo agentically, not from OpenAI's weights being categorically different from Anthropic's. CodeRabbit demonstrates this: same vendor family as Claude, but a purpose-built review pipeline (AST + lint + dep-graph + repo context) catches things Claude's general-purpose harness misses.

The current panel (Anthropic+general + OpenAI+agentic + Anthropic+review-pipeline) trades pure cross-vendor diversity for grounded findings. The user-as-tiebreaker is the third leg of the stool: when reviewers can't agree, the human picks the goal, not the implementation detail.

In real use, this kind of cross-harness review has caught issues a single general-purpose review missed — most often because the reviewer stayed too high-altitude or because the underlying model shared the same blind spot as the implementer. Cross-model agreement rate on findings tends to land in the 20–40% range, which is exactly the point: the disagreements are where the value lives. This rule converts the pattern from "ad-hoc when I remember" into three hard gates: parallel planning at request time (catches architecture), post-implementation review when code is "done" (catches bugs, edge cases, migration risk, and test gaps while there's still room to fix them cheaply), and pre-commit review on the final diff (catches anything the post-implementation pass missed in the exact shape that's about to land).
