# The five-vendor review panel

> Replaces the old `three-vendor-review-gate.md`. The panel grew to five on 2026-07-17.
>
> **The authority for every fact on this page is [`../rules/multi-ai-harness.md`](../rules/multi-ai-harness.md)** (contract-id `multi-ai-harness-v2`), which both Claude and Codex load every session. If this doc and the contract disagree, the contract wins. That indirection exists so a panel change is edited in exactly one place instead of being copy-pasted into five host docs that then rot at different rates.

## Why more than one reviewer

A model reviewing its own work shares its own assumptions — it cannot see what it did not think of. Two models with overlapping training data still share most of those assumptions. The signal comes from stacking two independent axes:

- **Harness diversity.** Codex explores files agentically. CodeRabbit runs AST + lint + repo context server-side. Kimi does an independent agentic pass in an isolated worktree. Each finds a different *class* of defect.
- **Vendor diversity.** Anthropic, OpenAI, Moonshot, and Zhipu train on substantially different corpora. Moonshot's K-series and Zhipu's GLM are the least correlated with the Western labs — that is precisely their value.

GLM's harness is Claude-shaped (it runs the `claude` CLI against z.ai's Anthropic-compatible endpoint), so its marginal contribution is the *weights*, not the harness. That's a documented, accepted overlap, not an oversight.

Concrete payoff from the original two-vendor version: Codex caught 7 issues Claude's own review missed by staying too high-altitude, and cross-model agreement ran about 30%. One reviewer was not enough. Five gates the assumption space far more thoroughly.

## Who sits on which gate

| Gate | Panel | Notes |
|---|---|---|
| **T1 — planning** | Claude + **one** OpenAI voice + Kimi + GLM | Independent plans, harvested (see [`planning-by-harvest.md`](planning-by-harvest.md)). CodeRabbit excluded — it's a review-only harness and cannot synthesize a plan. |
| **T2 — post-implementation** | Claude + Codex + Kimi + GLM | Symmetric: all four scrutinize the same diff. CodeRabbit held back to ration CLI credits. |
| **T3 — pre-commit** | Claude + Codex + CodeRabbit + Kimi + GLM | Final gate on the exact diff about to land. |

Two roster rules that are easy to get wrong:

- **OpenAI is one brain in two harnesses.** Codex (`gpt-5.6-sol`, grounded in the repo) and ChatGPT (business/strategy, clean chat) are the *same model*. Use whichever fits the task; never run both on one plan and never count them as two opinions. ChatGPT is **never** a reviewer.
- **Gemini is in no gate.** Removed 2026-07-17 after fabrications on 07-08 and 07-13. It remains available ad-hoc by explicit request, and has a sanctioned utility role (cheap batch LLM, cheap image generation) — generation, not judgment. Cost was never the reason it was benched, so "it's free now" doesn't bring it back.

## What counts as non-trivial

The gates fire only for non-trivial work. Non-trivial = **any** of:

- Touches more than one file
- More than three steps
- Schema migrations, auth changes, data flow, or external API contracts
- Payment, billing, or PII handling
- Any change under a directory you've declared high-risk (in the source setup, `scraper/` — even a one-line tweak)

Trivial work skips T1 and T2, but **T3 still runs before every commit**: typos, single-line changes, renames, comments, formatting, config-only edits, and test-only edits.

Conflicts resolve *toward* non-trivial. A test-only edit inside the high-risk directory hits the directory rule and runs the full gate. A config edit that also touches a `.ts` file is no longer config-only.

## The three gates in order

```text
 1. Request arrives
 2. T1  planning  ────► 4 independent plans, harvested into one, user approves
 3. Implementation
 4. T2  post-impl ────► Codex + Kimi + GLM agents in parallel; Claude's own pass
                        in parallel with them. Focus: implementation bugs,
                        missed edge cases, migration hazards, test gaps.
 5. User decides: fix / add tests / override / proceed
 6. Test suite runs (cheap, fast-fail — before the expensive reviewers)
 7. T3  pre-commit ───► all five on the final diff
 8. git commit
```

T2 deliberately runs **before** the test suite. Test gaps surfaced at T2 can be filled in the same pass, so the suite runs once with full coverage instead of twice. T2 is broad ("does this implementation hold up?"); T3 is narrow ("is this exact diff safe to land?").

Claude's own structured pass is a real panelist, not a formality — it runs inline, in parallel with the agents, using the same severity classes. Skipping it makes T2 a three-reviewer gate wearing a four-reviewer label.

## On findings — this is a hard gate

1. Surface findings **verbatim**, grouped by reviewer (`## Claude Review`, `## Codex Review`, `## CodeRabbit Review`, `## Kimi Review`, `## GLM Review`). No summarizing, no filtering, no severity downgrades.
2. **Mark convergence.** 2+ reviewers on the same line = HIGH-CONFIDENCE. 3+ = VERY-HIGH. 4–5 = near-certain blocker.
3. **Note divergence.** A lone finding is presented as-is with the reviewer's name. The user decides whether it's a real edge case the others missed or a false positive.
4. **Stop.** No commit, no push, no continuing the plan.
5. The user decides: fix, override, or ship. An override gets recorded in the commit body with the overridden reviewer's name, so it's auditable later.

The assistant never autonomously overrules a reviewer, including on findings that look obviously minor. The human-as-tiebreaker is the load-bearing leg: when reviewers disagree, only the human knows which goal actually matters.

## Verify every finding before you act on it

Grounded harnesses still hallucinate. Before applying any fix or escalating any finding to blocker:

1. Grep for the cited symbol in the cited file.
2. Read the cited line range.
3. If the symbol/line doesn't exist, or the finding describes behavior that's the literal opposite of what's on disk — mark it **HALLUCINATED** and log it.

Not hallucinations: line numbers off by ≤3, slightly misnamed symbols that resolve unambiguously, "missing test" findings you can't confirm from the diff alone. Only verifiable fabrications count.

```bash
LOG="/tmp/ai-reviewer-hallucinations-$(basename "$(git rev-parse --show-toplevel)").log"
printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "glm" \
  "claimed function X exists in file Y" "grep returns no match in file Y" >> "$LOG"
```

**At 2 verified hallucinations in one session, that reviewer is benched for the rest of the session.** Two reviewers benched = degraded panel, tell the user. A majority benched = stop; that pattern usually means the diff shape is confusing every harness, and the fix is to split the work into smaller commits.

The counter is per-worktree and per-session, and resets on a fresh session. Hallucination rate varies wildly by diff shape, so a persistent blacklist would penalize the wrong dimension. That said, the mechanism *is* how vendors get rotated out for real — it's how Gemini was swapped out in May, re-introduced, and finally removed in July.

## When a reviewer fails

| Situation | Response |
|---|---|
| Codex auth | Surface the exact error; user runs `codex login`. Never bypass. |
| Codex usage limit | Retry once with `-m gpt-5.5`. If that's also capped, the cap is account-wide — treat as one reviewer down and surface the reset time. Note in the findings heading which model ran. |
| CodeRabbit auth | `coderabbit auth login` — **and** check the GitHub App is installed on the org. |
| Kimi auth | `kimi login`. ⚠️ Unauthenticated `kimi` prints `LLM not set` and **exits 0** — trust the wrapper's exit 4, never the raw exit code. |
| Kimi quota | Managed subscription burns native Extra Usage automatically. On exact exhaustion, `kimi-review` retries once against the paid Open Platform endpoint and announces the billing source. Generic errors and rate limits never trigger paid usage. |
| GLM no key / 401 | Re-store the Keychain entry (see [`secrets.md`](secrets.md)). The wrapper deliberately does **not** fall back to your Anthropic auth — that would bill the wrong vendor and defeat the entire point of a cross-vendor panel. |
| GLM quota | No waterfall (dropping tiers trades away too much review quality). One reviewer down. |
| **One or two reviewers fail** | Gate is **PARTIALLY MET**. Present the working reviewers' findings *and* the failure. User decides: retry, proceed with reduced coverage, or fix and re-run. Don't auto-block, don't silently degrade. |
| **A majority fail** | **Stop.** Without meaningful review, nothing ships. |
| No diff in scope | Skip silently and proceed. |

### Don't kill a slow reviewer

The old flat 5-minute timeout was aborting healthy reviews. Measured latency: a 10KB diff takes ~4 min, 30KB ~6.5 min, and 74KB has needed up to ~15 min, with large run-to-run variance. The wrappers self-bound and always terminate — let them.

- `kimi-review`: 600/900/1200s by prompt size, then slice-on-timeout, hard 1800s ceiling.
- `glm-review`: 600s. Pin `--model glm-4.7` on large scopes; `glm-5.2` has been observed hanging.
- Intervene only past **the wrapper's own bound + ~2 min grace** — that means the wrapper is wedged, not the model being slow.

⚠️ **`kimi-review` exit 65 = PARTIAL COVERAGE.** Slicing recovered only some slices; the output opens with a `KIMI REVIEW COVERAGE: n of N` + `INCOMPLETE` banner. Treat that leg as DEGRADED, never clean — "no findings" on a partial run is not evidence of absence. The first cut of this feature returned exit 0 after reviewing 1 of 4 slices, which would have graded a quarter of a diff as the whole thing. Exit 0 means every slice was reviewed.

## Two wrapper traps worth memorizing

- **`-p` and piped stdin are mutually exclusive** in both `kimi-review` and `glm-review`. There is no separate diff channel — the diff must be embedded *in* the prompt. Until 2026-07-25 both wrappers silently discarded the pipe when `-p` was present, so `git show X | kimi-review -p "review this"` returned a confident review of the repo at HEAD instead of commit X. Both now exit 2.
- **Codex must run inside a trusted git repo.** From a non-repo directory it aborts with `Not inside a trusted directory`. This fails *closed* (exit 1, empty stdout), so it can't be mistaken for a clean review. And when checking any wrapper's exit code, never write `cmd | tail` — `$?` is then the pipe's status, not the tool's. Redirect to a file and test directly.

## When the reviewer wrote the code

If an engine implemented the diff (see [`implementation-fallback.md`](implementation-fallback.md)), that engine still reviews — but **advisory-only**: excluded from convergence counting and from the failure math. Mixed authorship counts as authored. Quorum is recomputed from the remaining eligible panel.

| Example | Eligible N | PARTIALLY MET | STOP |
|---|---|---|---|
| Codex-authored T2 | 3 (Claude+Kimi+GLM) | 1 fails | 2 fail |
| Codex-authored T3 | 4 (+CodeRabbit) | 1–2 fail | 3 fail |
| Normal T2 | 4 | 1–2 fail | 3 fail |
| Normal T3 | 5 | 1–2 fail | 3 fail |

Record `authored by: <engine>` in any handoff or session summary, so the advisory rule survives context compaction.

## Running it manually

```bash
# every available vendor against the same diff, outside the gates
~/.claude/scripts/cross-ai-review.sh

# or one leg at a time
codex exec review --uncommitted
coderabbit review --uncommitted --include-untracked
```

⚠️ `--include-untracked` is **mandatory** for uncommitted CodeRabbit scope since CLI 0.7.0. Without it, brand-new untracked files are silently dropped and the gate reports clean on an incomplete diff. (0.7.0 also removed `--plain` — plain is the default now and passing the flag errors.)

## Cost

Gates run in parallel, so wall time is the slowest leg: 1–4 min typical, longer on big diffs. Codex bills the OpenAI plan, Kimi the Kimi Code plan, GLM per-prompt on z.ai, CodeRabbit against rationed CLI credits. That's the price of the safety net, and it is cheap relative to one bad migration.
