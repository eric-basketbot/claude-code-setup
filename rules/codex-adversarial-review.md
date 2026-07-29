# Cross-Vendor Adversarial Review (Claude + Codex + CodeRabbit + Kimi + GLM)

<!-- panel-version: 2026-07-28.1 — must match ~/.codex/skills/adversarial-review/SKILL.md; enforced by the ai-config audit (rules.panel_version). When changing panel composition: edit the shared contract FIRST (~/.claude/rules/multi-ai-harness.md, contract-id: multi-ai-harness-v2), then add a History entry here, bump BOTH markers, and mirror the Codex twin skill. -->

> Filename retains `codex-adversarial-review.md` for backward compatibility. This file is Claude's ORCHESTRATION PROCEDURE for the panels. The **facts** — panel rosters per trigger, engine models and waterfalls, wrapper paths, permission matrix, authored-diff quorum table, hallucination policy — live in the shared contract `~/.claude/rules/multi-ai-harness.md` (contract-id: multi-ai-harness-v2), which both hosts load every session and which **overrides this file on any conflict**.
>
> Roster summary (see contract for the authoritative version): **T1 planning** = Claude (editor) + OpenAI voice (Codex technical / ChatGPT business — same model, never both) + Kimi + GLM, independent plans that Claude steelmans and HARVESTS (not a vote). **T2 post-implementation** = Claude + Codex + Kimi + GLM. **T3 pre-commit** = + CodeRabbit. **Gemini is in NO gate** (ad-hoc only; cheap image-gen/batch utility per user directive). ChatGPT is never a reviewer.

> **One-time install preconditions (per-repo / per-machine):**
> - CodeRabbit requires its GitHub App installed on the repo's GitHub org/account before `coderabbit review` works. CLI auth (`coderabbit auth login`) is NOT enough. Install at https://github.com/apps/coderabbitai → select the org (e.g. `<your-github-org>`) → grant access to the specific repo. If `coderabbit review --uncommitted --include-untracked` returns "CodeRabbit could not connect this repository to a CodeRabbit organization," the install is missing.
> - **CLI 0.7.0 flag contract (upgraded 2026-07-25 from 0.6.5):** `--plain` was removed (plain is the default; passing it now errors), `-t/--type` is a hidden legacy selector that conflicts with the new `--committed`/`--uncommitted` flags, and **`--include-untracked` is mandatory for uncommitted scope** — without it, brand-new untracked files are silently dropped from the review and the gate reports clean on an incomplete diff. `--committed` conflicts with `--include-untracked`.
> - Kimi requires a one-time `kimi login` (browser OAuth). Creds/config under `~/.kimi/`. GOTCHA: unauthenticated `kimi` prints `LLM not set` and exits 0 — the `kimi-review` wrapper converts that to exit 4. Read-only is structural (disposable-worktree isolation), not a flag.
> - GLM needs the z.ai key (the full `{API Key ID}.{secret}` dotted string — the Anthropic-compatible endpoint takes it directly as the Bearer token; no JWT signing). **Since 2026-07-25 it lives in the macOS Keychain** under service `ai-config.<project>.ZAI_API_KEY`; `glm-review` reads it from there, and an exported `$ZAI_API_KEY`/`$ZAI_AUTH_TOKEN` still takes precedence. It used to be a plaintext `export` in `~/.zshrc`, which the ai-config audit flagged (`security.config_files` / `literal_credential_assignment`) — that literal has been removed. Re-store after a rotation with `security add-generic-password -U -a "$(id -un)" -s ai-config.<project>.ZAI_API_KEY -w` — **`-w` MUST be the final argument with nothing after it**, so `security` prompts (twice) and the key stays out of argv and shell history. ⚠️ Any flag placed after `-w` is silently swallowed AS the password; the old `-w -U` ordering stored the literal string `-U` with exit 0, no prompt and no error. NEVER paste the key into chat. If no source yields a token, `glm-review` exits 4 with instructions (it does NOT fall back to Anthropic auth). Read-only is structural (tool allowlist Read/Grep/Glob + external cwd so this repo's hooks never load), not a flag.

Each external reviewer is invoked via its dedicated agent so findings come back unfiltered:

- **`codex-reviewer` agent** (`~/.claude/agents/codex-reviewer.md`) — wraps `codex exec review` with `--base`, `--uncommitted`, `--commit` scoping. Agentic — Codex reads surrounding files during review.
- **`coderabbit-reviewer` agent** (`~/.claude/agents/coderabbit-reviewer.md`) — wraps `coderabbit review` with `--uncommitted --include-untracked`, `--committed`, `--base`, `--base-commit` scoping. Server-side harness — AST + lint + repo context grounds every finding.
- **`kimi-reviewer` agent** (`~/.claude/agents/kimi-reviewer.md`) — wraps `kimi-review`; the diff is EMBEDDED IN the prompt, piped on stdin. Runs Kimi read-only inside a disposable git worktree.
- **`glm-reviewer` agent** (`~/.claude/agents/glm-reviewer.md`) — wraps `glm-review`; same embed-in-prompt contract. Runs `claude` on a GLM model via z.ai, read-only via tool allowlist + external cwd, grounded via `--add-dir`.
- ⚠️ **Both of the above: `-p` and piped stdin are MUTUALLY EXCLUSIVE — never pass both.** There is no separate diff channel. Until 2026-07-25 both wrappers silently DISCARDED the pipe when `-p` was present, so `git show X | kimi-review -p "review this"` returned a confident review of the repo at HEAD rather than X. Both now exit 2 on that combination.
- **`/review`** (gstack skill at `~/.claude/skills/gstack/review/`) — pre-landing review, alternative entry point.
- **`~/.claude/scripts/cross-ai-review.sh`** — manual aggregator that runs every available AI CLI against the same diff. Use for ad-hoc review outside the trigger gates.

Claude's own structured pass is NOT a separate agent — the running session does it inline as part of Triggers 2 and 3 (see § Trigger 2 / Trigger 3 below).

## What counts as non-trivial

These rules fire ONLY for non-trivial requests. Non-trivial = ANY of:
- Touches more than one file
- More than three steps
- Schema migrations, auth changes, data flow, or external API contracts
- Scraper logic that writes to prod data
- Payment, billing, or PII handling
- **Any change under `scraper/`** (regardless of size — even a one-line scraper tweak runs the gate)

Trivial fixes skip planning and post-implementation review (Triggers 1 and 2).
Trigger 3 still runs before any commit:
- Typo, single-line change, rename, comment, formatting
- **Config-only edits** (changes confined to config files: `*.json`, `*.yaml`, `*.toml`, `.env*`, `config/**`, with no logic changes)
- **Test-only edits** (changes confined to test files: `*.test.*`, `*.spec.*`, `tests/**`, `__tests__/**`, with no production code touched)

Conflicts resolve toward non-trivial: a `scraper/` test edit hits the scraper rule and runs the gate. A config edit that also touches a `.ts` file is no longer config-only.

## Trigger 1: Hybrid planning (independent plans, Claude harvests)

For non-trivial requests, planning is a set of **independent** plans that Claude, as editor, **harvests the best pieces from.** It is NOT a vote, and it is NOT specialists reacting to a shared draft — each invited voice frames the problem fresh, so nothing is anchored. Only genuinely trivial changes skip the panel.

### The voices (no cost/task gating)

Invite every applicable voice for any substantive plan — the Kimi/GLM/Codex/ChatGPT limits are high, and under *harvesting* (not voting) more voices is strictly better: disagreement becomes raw material for the editor, not a stalemate.

- **Claude** — always; primary planner AND editor/decision-maker.
- **OpenAI voice — pick the harness that fits, do NOT run both:**
  - **Codex** (`codex exec --sandbox read-only`) for **technical/repo** plans — grounds on the repo.
  - **ChatGPT** (`chatgpt-plan` via the `chatgpt-planner` agent) for **business/strategy/writing** plans — clean chat, right-shaped for non-technical work.
  - ⚠️ Codex and ChatGPT are the SAME model (`gpt-5.6-sol`) in two harnesses. Use whichever fits; do NOT run both on one plan (same brain twice) and do NOT count them as two independent opinions.
- **Kimi** (`kimi-review`) — independent plan; especially valuable when there's large supporting material (long-context strength).
- **GLM** (`glm-review`) — independent plan / cheap extra frame; leans toward the simplest, cheapest approach.

Distinct-model diversity = **Claude + OpenAI + Kimi + GLM** (four different models). CodeRabbit is excluded from planning (review-only harness — it can't synthesize a plan).

### Step 1 — dispatch the invited external voices in parallel

Ask each for its own FULL INDEPENDENT plan (approach/positioning, assumptions, priorities, files-or-milestones, risks). Do not paraphrase into a shared draft — each frames fresh.

```bash
# Technical/repo plan — Codex (grounded):
codex exec --sandbox read-only "<request, verbatim> — produce an independent implementation plan: approach, files, sequencing, risks, milestones. Examine the repo as needed." < /dev/null

# Business/strategy/writing plan — ChatGPT (instead of Codex; same OpenAI brain, better harness):
~/.local/bin/chatgpt-plan -p "<request, verbatim> — produce an independent plan: positioning/approach, assumptions, priorities, first milestones, top risks, and the single most important thing to validate first."

# Always (both plan types):
~/.local/bin/kimi-review -p "<request, verbatim> — produce an independent step-by-step plan: approach, assumptions, sequencing, risks. Read the repo/material as needed." < /dev/null
~/.local/bin/glm-review -p "<request, verbatim> — produce an independent plan: approach, assumptions, steps, risks; prefer the simplest/cheapest approach that meets the goal."
```

Read-only safety (unchanged): Codex `--sandbox read-only` (never workspace-write at planning — it would implement instead of propose); Kimi runs read-only in a disposable worktree; GLM runs read-only via tool allowlist + external cwd; ChatGPT is a pure API call (no tools). `< /dev/null` is required when the prompt is an argument (Codex/Kimi/GLM) so they don't stall on stdin; `chatgpt-plan` takes `-p` or piped stdin.

If the prompt depends on prior conversation context the others lack, prepend the minimum context to make it standalone; mark what you added. If a voice hits quota/auth trouble, surface it and proceed with the ones that returned.

### Step 2 — Claude plans in parallel

While the external voices run, form Claude's own full plan. Don't idle.

### Step 3 — Claude harvests (the editor step)

Claude is the editor/decision-maker. Do NOT concatenate the plans into one huge document — that "verbatim, grouped by reviewer" behavior belongs to the *review* gate, not here.

1. **Steelman each plan first** — for every plan (including Claude's own), note explicitly what it got right that the others missed. This is the guard against editor bias / over-favoring Claude's own plan.
2. **Harvest the best pieces** into one plan — a strong idea from an otherwise-weak plan still makes it in. Harvesting, not voting: minority insight survives.
3. **Coherence pass** — the merged plan must be internally consistent, not a graft of locally-good parts.
4. Present **one** Claude-edited plan.

### Step 4 — surface genuine forks; user approves

If the voices diverged on a FUNDAMENTAL approach (not just detail), present the fork with each option side-by-side (one line per approach + one sentence on the core tradeoff) and let the user pick — the user is the tiebreaker on real approach-forks. Otherwise present the synthesized plan. Either way the user approves before work starts. Record a notable rejected approach in the commit body if relevant.

### Cost

Adaptive: often just Claude for a simple plan; the panel convenes by need. Parallel calls, so wall time ≈ the slowest external voice (1–3 min). Codex bills the OpenAI plan; ChatGPT rides the ChatGPT subscription (same login as Codex); Kimi the Kimi Code plan; GLM the z.ai plan. CodeRabbit is not called at planning.

### Scope

This hybrid-harvest model is **Trigger 1 (planning) ONLY.** Triggers 2 & 3 (review) stay symmetric — every reviewer independently scrutinizes the same diff, because there the value is uncorrelated same-target passes, not divided labor. ChatGPT is **not** a review panelist.

## Trigger 2: After implementation completes (post-implementation review)

For non-trivial work, run an adversarial review the moment implementation is "done" — before running the test trio, before staging, before any commit prep. This late review catches what planning can't see: implementation bugs, missed edge cases, migration hazards, and test gaps.

The point of running this BEFORE tests (not after) is that test gaps surfaced here can be filled in the same pass — you write the missing tests, then run the trio once with full coverage.

### How to invoke

Invoke the `codex-reviewer`, `kimi-reviewer`, AND `glm-reviewer` agents in parallel — single message, three `Agent` tool calls — with uncommitted scope and explicit focus on the four post-implementation concerns. (CodeRabbit is NOT invoked at Trigger 2 — it runs only at Trigger 3 on the final diff.)

- **Implementation bugs**: logic errors, off-by-one, wrong operator, swapped arguments, broken control flow
- **Missed edge cases**: nulls/empties, unicode, timezone, concurrency, partial failure, retry semantics, idempotency
- **Migration hazards**: schema changes that lock hot tables, backfills that don't tolerate concurrent writes, irreversible drops, FK CASCADE blast radius, data loss on rollback
- **Test gaps**: new code paths without tests, modified branches without coverage, integration seams without fixtures, mocked-where-real-needed

Tell each reviewer these four are the focus — don't let them spend their budget on style nits.

**Claude's own pass runs in parallel with the agents** (use the latency while the three agents work): read the diff yourself, apply the same FORCE-stance rubric with the same severity classes (CRITICAL / IMPORTANT / SUGGESTION), and produce a structured Claude review for the same four concerns. Surface Claude's findings under a `## Claude Review` heading alongside the three agent outputs. This is the fourth panelist — without it the Trigger-2 panel is 3-reviewer despite the heading.

### Order in the post-implementation flow

1. Implementation done (Claude believes work is complete)
2. **Post-implementation review (this trigger)** ← Codex + Kimi + GLM agents run in parallel; Claude does its own pass in parallel; surfaces bugs/edge-cases/migration risks/test gaps. CodeRabbit is held back for Trigger 3.
3. User decides: fix findings (from any reviewer), add tests, override, or proceed
4. After fixes: pre-commit test trio (`vitest`, `api-contracts`, `playwright`)
5. Pre-commit review (Trigger 3, on the final diff)
6. `git commit`

Same hard-gate semantics as planning: surface findings verbatim from all four reviewers (Claude + Codex + Kimi + GLM), stop, wait for user.

### When to skip

- Trivial fixes (per the "What counts as non-trivial" section above)
- Implementation made zero behavior changes (pure rename, formatting, comment-only)
- The diff at this stage is identical to what the pre-commit gate (Trigger 3) will see AND there are no test gaps to address — collapse to just Trigger 3. Default to running both unless you're sure.

## Trigger 3: Before every `git commit`

After tests pass and before `git commit`, invoke the `codex-reviewer`, `coderabbit-reviewer`, `kimi-reviewer`, AND `glm-reviewer` agents in parallel with uncommitted scope, AND do Claude's own structured pass on the same diff. This is the final pre-commit adversarial gate — a five-perspective sanity check on the exact diff that's about to land.

This fires for every commit, including on feature branches and worktrees. The cost (1–4 min, parallel) is the price of the safety net.

The pre-commit test trio (`vitest`, `api-contracts`, `playwright`) and the cross-harness review run in this order: tests first (cheap, fast-fail), then all four external agents + Claude's own pass in parallel (slow, deep). Don't run reviewers if tests are red.

Trigger 2 vs Trigger 3: Trigger 2 is broad ("does this implementation hold up?"), Trigger 3 is narrow ("is this exact diff safe to land?"). Trigger 2 may surface issues whose fixes change the diff; Trigger 3 reviews the final shape after those fixes settle.

## On findings (hard gate)

When Codex, CodeRabbit, Kimi, GLM, and/or Claude return findings:

1. Surface them VERBATIM to the user, **grouped by reviewer** (`## Claude Review`, `## Codex Review`, `## CodeRabbit Review`, `## Kimi Review`, `## GLM Review` headings in that order). At Trigger 2 the `## CodeRabbit Review` heading is omitted (CodeRabbit is not invoked there). Don't summarize, don't filter, don't downgrade severity.
2. **Highlight convergence**: if 2+ reviewers flag the same line/concern, mark it **HIGH-CONFIDENCE** at the top of the report. 3+ converging = **VERY-HIGH-CONFIDENCE**. 4–5 converging = treat as a near-certain blocker.
3. **Note divergence**: if only one flags an issue, present it as-is with reviewer name. The user decides if it's a real edge case the others missed or a false positive.
4. STOP. Do not proceed with the plan, do not run `git commit`, do not push.
5. Wait for the user to decide: fix, override, or ship as-is.

The user makes the call on every finding. Claude does not autonomously override any reviewer's objections, even on issues that look minor or look like false positives. If a reviewer flags it, the user sees it and decides.

If the user says "ignore that finding" or "ship anyway", proceed — but record the override in the commit message body so it's auditable, and note which reviewer's finding was overridden.

## Codex-authored diffs (Opus-fallback implementation)

When Codex implemented the diff under the Opus-fallback protocol
(`~/.claude/rules/opus-fallback-implementation.md`), Codex still runs at Triggers 2
and 3, but its review of its own diff is **advisory-only**: label it
`## Codex Review (advisory — authored this diff)`, and exclude it from convergence
counting (HIGH-CONFIDENCE math) and from the reviewer-failure/majority calculus.
Mixed authorship counts as Codex-authored. The effective independent panel is
Claude + Kimi + GLM at Trigger 2 and Claude + Kimi + GLM + CodeRabbit at Trigger 3 —
arguably stronger independence than usual, since Claude (the usual author) did not
write the diff. The grep-verify step and hallucination counter still apply to
Codex's advisory findings.

Generalization (any implementer engine — Codex, Kimi, …): whoever implemented
the diff reviews it advisory-only; an advisory failure counts as zero. Recompute
quorum from the remaining ELIGIBLE panel — a majority (more than half) failing =
STOP; fewer = PARTIALLY MET. This overrides the generic "one/two reviewers fail"
lines in § Failure modes (written for the normal 4–5 reviewer panels). The
worked threshold table lives in the shared contract
(`~/.claude/rules/multi-ai-harness.md` § Authored-diff advisory rule).

## Failure modes

- **Codex auth fails** (`codex login` needed or `OPENAI_API_KEY` missing): surface the exact error, do not bypass the gate. Tell the user to run `codex login`.
- **Codex usage limit** (`You've hit your usage limit`): retry the same command ONCE with `-m gpt-5.5` (user-directed 2026-07-10). Applies to planning and review (the `codex-reviewer` agent does this itself). If the fallback ALSO hits the limit, the cap is account-wide — treat as "one reviewer fails" and surface the reset time. When the fallback succeeds, note in the findings heading that Codex ran on gpt-5.5.
- **CodeRabbit auth fails** (`coderabbit auth status --agent` returns `authenticated:false`): surface the exact error, do not bypass the gate. Tell the user to run `coderabbit auth login`.
- **Kimi auth fails** (`kimi-review` exits 4, or output contains `LLM not set`): surface the exact error. Tell the user to run `kimi login`. GOTCHA: bare `kimi` exits 0 when unauthenticated — trust the wrapper's exit 4 / the `LLM not set` string, not the raw exit code.
- **Kimi quota / usage limit**: the managed subscription already consumes native Extra Usage. On an exact exhaustion response, `kimi-review` retries once on paid Open Platform `kimi-k3` using the Keychain key and announces that billing source. If the key is absent or that retry fails, treat it as "one reviewer fails" and surface verbatim. Generic errors and rolling rate limits never trigger paid usage.
- **GLM no key / auth fails** (`glm-review` exits 4, or output mentions `invalid api key` / `unauthorized` / `401`): surface the exact error. The key lives in the macOS Keychain (`ai-config.<project>.ZAI_API_KEY`); tell the user to re-store it with `security add-generic-password -U -a "$(id -un)" -s ai-config.<project>.ZAI_API_KEY -w` (`-w` MUST be last with nothing after it, so `security` prompts; a flag after `-w` is stored AS the password) — NEVER request or paste the key in chat. The wrapper does NOT fall back to Anthropic auth.
- **GLM quota / usage limit**: no auto-waterfall wired (dropping from `glm-5.2` to a lower tier trades away too much review quality) — treat as "one reviewer fails" and surface verbatim.
- **One reviewer fails, the rest succeed**: present the working reviewers' findings AND surface the failure. Treat the gate as PARTIALLY MET — the user decides whether to retry the failed reviewer, proceed with reduced coverage, or fix the cause and re-run. Default: ask the user. N−1 of N is still strong coverage; do not automatically block, but do not silently degrade either.
- **Two reviewers fail**: same logic — PARTIALLY MET, more degraded. Ask the user whether to retry, proceed, or wait.
- **A majority of reviewers fail**: stop. Without meaningful review, no shipping. Surface all errors and have the user fix at least enough to restore majority coverage before proceeding.
- **Reviewer hangs — DO NOT use a flat 5-minute kill.** That old threshold predates the 2026-07-25 latency measurements and was aborting healthy reviews: a 10KB diff takes ~4 min, 30KB ~6.5 min, and 74KB has needed up to ~15 min, with large run-to-run variance. The wrappers self-bound and always terminate, so let them:
  - `kimi-review`: first attempt 600/900/1200s by prompt size, then slice-on-timeout, with a **hard 1800s (30 min) ceiling for the whole invocation** (`$KIMI_REVIEW_TOTAL_CAP`). Typical run 4–8 min.
  - `glm-review`: 600s (`$GLM_REVIEW_TIMEOUT`). ⚠️ still pin `--model glm-4.7` or split on large scopes — glm-5.2 has been observed hanging.
  - Kill manually only if a reviewer exceeds **its own bound + ~2 min grace** (that means the wrapper itself is wedged, not the model being slow). Then surface the timeout and ask the user whether to retry or skip; skipping requires explicit user instruction.
  - Budget the gate for the slowest leg, and prefer running reviewers in parallel so a slow Kimi doesn't serialize the others.
- **No diff to review** (uncommitted scope returns nothing): skip silently, proceed to commit.
- **CodeRabbit diff-too-large**: split by directory (`--dir`) or by commit (`--base-commit`) and re-run. Don't drop coverage.

## Hallucination tracking (kept symmetric, applies to all reviewers)

A "hallucinated" finding is a reviewer claim that does not survive a 5-second grep/Read against the cited file/symbol/line. Wrong line numbers off by ≤3, slightly mis-named symbols that resolve unambiguously, or "missing test" findings whose tested-state you can't confirm in the diff alone do NOT count — only verifiable fabrications (cited symbol/file/migration does not exist, cited behavior is the literal opposite of what the code does).

All external reviewers have grounded harnesses (CodeRabbit: AST + lint + repo context; Codex: agentic file reads; Kimi: agentic file reads in the disposable worktree; GLM: agentic file reads via `--add-dir`), but no harness is perfect — the counter remains in place. Kimi and GLM are NEW to the panel (2026-07-17) with no track record here — apply the grep-verify step to their findings with extra care until they earn one.

### The verify step is mandatory

Before applying ANY reviewer fix or surfacing a finding as a blocker:

1. Grep for the cited symbol in the cited file.
2. Read the cited line range.
3. If symbol/line don't exist OR the finding describes code behavior that is contradicted by what's actually on disk: mark it **HALLUCINATED** in your write-up to the user, and append it to the session counter (next section).

### Session counter

Path: `/tmp/ai-reviewer-hallucinations-$(basename "$(git rev-parse --show-toplevel)").log`

Format: one TSV line per verified hallucination —
```
<iso-timestamp>\t<model>\t<short-finding-summary>\t<why-it-was-hallucinated>
```

Append via:
```bash
LOG="/tmp/ai-reviewer-hallucinations-$(basename "$(git rev-parse --show-toplevel)").log"
printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "glm" "claimed function X exists in file Y" "grep returns no match in file Y" >> "$LOG"
```

Models tracked: any reviewer in the active rotation — `codex`, `coderabbit`, `kimi`, `glm`. (Claude's own findings are also subject to the verify step but are not tracked in the counter — Claude is the orchestrator, not a benchable panelist.)

### Threshold → benched for the session

**Trigger**: a single model has ≥2 verified hallucinations in the current session's counter (one log file per worktree). Check the counter before every external-reviewer agent invocation:

```bash
LOG="/tmp/ai-reviewer-hallucinations-$(basename "$(git rev-parse --show-toplevel)").log"
codex_count=$(grep -c $'\tcodex\t' "$LOG" 2>/dev/null || echo 0)
coderabbit_count=$(grep -c $'\tcoderabbit\t' "$LOG" 2>/dev/null || echo 0)
kimi_count=$(grep -c $'\tkimi\t' "$LOG" 2>/dev/null || echo 0)
glm_count=$(grep -c $'\tglm\t' "$LOG" 2>/dev/null || echo 0)
```

**If any single count `>= 2`**: skip that reviewer's agent for the rest of the session. Run the remaining reviewers + Claude and note the gate is operating one panelist short. Tell the user once: "GLM hit 2 verified hallucinations this session — running the rest of the panel alone for remaining reviews. Counter at `/tmp/ai-reviewer-hallucinations-...log`."

**If two reviewers `>= 2`**: the panel is meaningfully degraded. Tell the user once and ask whether to proceed with reduced external coverage or stop to investigate.

**If a majority of external reviewers `>= 2`**: stop. The panel is broken. Surface the counter contents and have the user tiebreak — proceed with Claude only, retry with a smaller diff scope, or skip the gate with an explicit override recorded in the commit body. Many-at-once is suspicious — likely a diff shape confusing every harness; consider splitting the work into smaller commits.

### Counter scope & lifecycle

- **Scope is per-worktree, per-session.** Keyed to the worktree by `basename`. Cleanup hooks remove worktrees → the counter file disappears with them.
- **No carry-over across sessions.** A fresh session sees an empty counter — the point is to catch a streak within one session, not a vendor blacklist.
- **No carry-over across worktrees.** Parallel sessions each track their own counter.
- **Manual reset**: `rm /tmp/ai-reviewer-hallucinations-*.log`.

### Why not a persistent rolling log

Hallucination rate varies wildly by diff shape — a model that drifted on one prompt may be fine on the next, and a persistent log would penalize the wrong dimension. The always-grep-verify rule already catches the worst pattern. Per-session reset keeps the panel honest by default. If a vendor turns out persistently bad across many sessions, flip the rotation — file a feedback memory and edit this rule. (That is exactly the mechanism by which Gemini was swapped out 2026-05-15, re-introduced 2026-05-18, and removed for good 2026-07-17 in favor of Kimi.)

## Why

Single-model planning has a known blind-spot problem: a model reviewing its own work shares its own assumptions. Two-model consensus surfaces some disagreements but two models with overlapping training data still share many assumptions. Four or five uncorrelated harnesses + cross-vendor weights cover substantially more of the assumption space.

**On planning specifically (Trigger 1):** the old model reconciled independent plans by *voting* (majority approach wins). That discards minority insight — and the best idea is often in the one plan the others disagree with. So planning now reconciles by *editorial harvest*: Claude steelmans each plan and grafts the best pieces into one, keeping minority insight. Under harvesting (unlike voting), more voices is strictly better — disagreement is raw material, not stalemate — so there is no cost/task gating on who's invited. The one nuance: Codex and ChatGPT are the same OpenAI model in two harnesses (coding vs business chat), so they're correlated; treat them as one OpenAI voice used in whichever harness fits, and get real model-diversity from Claude + OpenAI + Kimi + GLM.

The strongest review signal comes from **both harness diversity and vendor diversity**:
- **Harness diversity** — Codex's agentic file exploration catches things Claude's general-purpose harness misses. CodeRabbit's AST + lint + repo-context pipeline catches things both miss. Kimi's independent agentic pass in an isolated worktree adds another uncorrelated read.
- **Vendor diversity** — different training corpora have different blind spots. Anthropic + OpenAI + Moonshot + Zhipu + a second Anthropic harness (CodeRabbit) is broad cross-vendor coverage. Moonshot's K-series and Zhipu's GLM are trained on substantially different corpora than the Western labs — different blind spots is the whole point. GLM's harness is claude-shaped (shared with the Claude panelist), so its marginal value is the WEIGHTS, not the harness; that's an accepted, documented overlap.

The user-as-tiebreaker is the load-bearing leg of the stool: when reviewers can't agree, the human picks the goal, not the implementation detail.

The gstack changelog v1.5.1.0 documented a real case: Codex caught 7 issues Claude's eng review missed by staying too high-altitude; cross-model agreement rate was ~30%. One reviewer was not enough. This rule converts the pattern from "ad-hoc when I remember" into three hard gates: parallel planning at request time (catches architecture), post-implementation review when code is "done" (catches bugs, edge cases, migration risk, and test gaps while there's still room to fix them cheaply), and pre-commit review on the final diff (catches anything the post-implementation pass missed).

History of panel composition:

Compact dated index — full prose per entry lives in memory
`meta/reference_panel_composition_history.md`. The `rules.panel_version` audit
ratchet parses these dates; every panel change adds a bullet here.

- **2026-07-28.1**: Kimi billing fallback added; panel ROSTER unchanged. Managed Kimi Code remains first and automatically consumes native Extra Usage. Only an exact managed-quota exhaustion may retry once on separately billed Open Platform `kimi-k3`, with `MOONSHOT_API_KEY` injected at runtime from macOS Keychain. Review and Opus-fallback implementation wrappers both preserve no-retry-over-partial-edits and announce paid usage. Shared contract bumped to `multi-ai-harness-v2` because the implementation ladder gained a rung.
- **2026-05-15**: Gemini OUT (ungrounded `gemini -p` fabrications) -> CodeRabbit IN.
- **2026-05-18**: Gemini re-introduced alongside CodeRabbit (grounded CLI verified) -- 4 reviewers.
- **2026-05-28**: CodeRabbit rationed to Trigger 3 only (CLI credit caps).
- **2026-06-18**: Google killed the Gemini CLI for individual OAuth tiers.
- **2026-06-19**: Google leg migrated to Antigravity (`agy-review`, Gemini 3.1 Pro, read-only).
- **2026-07-17**: Gemini removed for good (fabrications 07-08 + 07-13) -> Kimi (Moonshot) IN.
- **2026-07-17 (same day)**: GLM (Zhipu/z.ai) added as 5th panelist.
- **2026-07-18**: T1 planning reworked to independent-plans-by-HARVEST; ChatGPT business-planning voice added (same model as Codex -- one OpenAI brain, planning only, never a reviewer).
- **2026-07-18 (later)**: Opus-fallback implementation protocol (Codex implements when Claude runs on a fallback model); Codex twin skill rewritten from the stale two-party model; panel-version markers + `rules.panel_version` audit check; kimi/glm/chatgpt-planner declared in topology + Codex symlinks; GLM default corrected to glm-5.2.
- **2026-07-25.3**: GLM key moved from a plaintext `export ZAI_API_KEY=` in `~/.zshrc` to the macOS Keychain (service `ai-config.<project>.ZAI_API_KEY`, same store the MCP servers use via `keychain-exec.sh`). Panel ROSTER unchanged. `glm-review` now resolves the token env-first (`$ZAI_API_KEY`/`$ZAI_AUTH_TOKEN` still win, for CI and one-off overrides) then falls back to the Keychain; call sites are untouched, so the `glm-reviewer` agent and `cross-ai-review.sh` needed no changes beyond doc text. Motivation: the literal tripped the ai-config audit's `security.config_files` / `literal_credential_assignment` check — a plaintext secret in a dotfile is readable by anything that can read the file and leaks into any shared or screen-shared shell profile. Verified end-to-end from a fresh login shell with the env vars unset. With this the audit is 20/20 PASS, 0 findings.
- **2026-07-25.2b** (same-day addendum, no roster change): **Panel health-checked end to end** — Codex upgraded 0.144.3 → **0.145.0** and re-smoke-tested (exit 0 in-repo); CodeRabbit 0.7.0 authenticated + a real review returned "No findings"; Kimi 1.49.0 (already latest) and GLM both functional. New Codex fact: it **must run inside a trusted git repo** — from a non-repo dir it aborts with `Not inside a trusted directory and --skip-git-repo-check was not specified`, and this **fails CLOSED (exit 1, empty stdout)**, so it cannot be mistaken for a clean review. ⚠️ Measurement note that produced an initial WRONG "exits 0" claim: `cmd | tail` makes `$?` the pipe's status — always redirect to a file when checking a tool's exit code. **Gemini/Antigravity re-confirmed AD-HOC ONLY by user directive**: `@google/gemini-cli` is permanently dead for this account (`IneligibleTierError` for "Gemini Code Assist for individuals", any version), while `agy`/Antigravity works and is free on the user's Google AI Pro — but cost was never the reason it was benched, and the 07-08/07-13 fabrications happened on the Antigravity harness itself, so it stays out of every gate.
- **2026-07-25.2**: Kimi/GLM wrapper hardening. Panel ROSTER unchanged. (a) **`-p` + piped stdin silently DISCARDED the pipe in BOTH `kimi-review` and `glm-review`** — `git show X | kimi-review -p "..."` reviewed the repo at HEAD instead of X, i.e. a confident review of the WRONG code with no warning; both now exit 2. (b) Kimi's "large-diff hang" re-diagnosed as a TIME problem, not a model problem: `~/.kimi/config.toml` already has `default_model = "kimi-code/k3"`, so the hangs prior sessions blamed on K2.7 happened ON K3 (30KB timed out at 420s then finished in 388s; 74KB gave 0 bytes at 600s but a full review at 900s). `kimi-review` now size-scales the timeout (600/900/1200s) and, on timeout, slices the diff on `diff --git` boundaries and concatenates per-slice reviews (marked `===== SLICE n/N =====`, DEGRADED — no cross-file reasoning; bounded by `timeout/2` per slice and a 1200s total budget). **Slicing that recovers only SOME slices exits 65 with a `KIMI REVIEW COVERAGE: n of N` + `INCOMPLETE` banner — treat that leg as PARTIALLY MET, never clean** (the first cut returned exit 0 after recovering 1 of 4 slices; a gate accepting that would have graded a quarter of the diff as the whole). (c) `--model` is validated against config.toml — a bare `k3`/`kimi-for-coding` prints `LLM not set` + exit 0, which the wrapper used to report as a bogus "not authenticated". (d) `kimi-reviewer` SKILL.md's hardcoded `--timeout 300` removed (below the wrapper's own default; shorter than a 172-line diff takes).
- **2026-07-25.1**: CodeRabbit CLI upgraded 0.6.5 -> 0.7.0 (Homebrew cask). Panel ROSTER unchanged -- this is a flag-contract migration. 0.7.0 removed the legacy aliases (`--plain`, `--fast`, `--cwd`, `--interactive`; `--prompt-only` stays retired in favor of `--agent`), so `--plain` is now a hard `unknown option` error; `-t/--type` survives only as a hidden legacy selector that CONFLICTS with the new `--committed`/`--uncommitted`; and `--include-untracked` is now REQUIRED for uncommitted scope -- 0.6.5 folded untracked files into `--type uncommitted`, 0.7.0 silently drops brand-new files without it (verified against both binaries: `includeUntracked` is gated solely on the flag), which would make a gate report clean on an incomplete diff. All five call sites migrated: the `coderabbit-reviewer` agent, `cross-ai-review.sh`, this file, the shared contract's permission matrix, and the Codex twin skill.
- **2026-07-18.3 (later-2)**: Panel FACTS extracted to the shared contract `~/.claude/rules/multi-ai-harness.md` (contract-id: multi-ai-harness-v1, synced to both hosts; `harness.shared_contract` audit check). Implementation ladder gained a KIMI rung by user directive -- sol -> Kimi -> gpt-5.5 -> orchestrator -- enforced by `codex-implementation-fallback.sh` (12 tests; Kimi rung has no OS sandbox, contained by sentinel + git guard + worktree). Authored-diff advisory rule GENERALIZED to any implementer engine. Gemini's sanctioned utility role recorded: cheap image generation (Flash tier) + cheap batch LLM -- never gates. History prose relocated to memory.
