# Planning by editorial harvest

The single biggest behavioral change since the first version of this pack. Trigger 1 used to reconcile independent plans by **voting** — majority approach wins. It now reconciles by **editorial harvest** — one host steelmans every plan and grafts the best pieces into one.

## Why voting was wrong

Voting optimizes for the *median* plan. But the best idea in a planning round is frequently sitting in the one plan the other three disagree with — a cheaper migration path, an ordering constraint nobody else noticed, a risk only one model took seriously. A vote deletes exactly that.

Harvesting inverts the incentive. A strong idea from an otherwise-weak plan still makes it in. And because disagreement becomes *raw material* rather than a stalemate, more voices is now strictly better — which is why there is no cost or task gating on who gets invited.

## The voices

Invite every applicable voice for any substantive plan.

| Voice | Harness | Strength |
|---|---|---|
| **Claude** | the running session | Primary planner **and** the editor who makes the call |
| **OpenAI** | `codex exec --sandbox read-only` *or* `chatgpt-plan` | Codex for technical/repo plans (grounded in the code); ChatGPT for business/strategy/writing (right-shaped harness for non-technical work) |
| **Kimi** | `kimi-review` | Independent plan; especially strong when there's a lot of supporting material to hold at once |
| **GLM** | `glm-review` | Cheap extra frame; reliably argues for the simplest, cheapest approach that meets the goal |

**Pick one OpenAI harness, never both.** Codex and ChatGPT are the same model (`gpt-5.6-sol`) wearing two different harnesses. Running both is the same brain twice and must not be counted as two independent opinions.

Real model diversity is therefore **Claude + OpenAI + Kimi + GLM** — four distinct model families. CodeRabbit is excluded: it's a review-only harness and can't synthesize a plan.

## The procedure

### Step 1 — dispatch the external voices in parallel

Each gets the request **verbatim** and is asked for its own full independent plan. Do not paraphrase into a shared draft — the entire value is that nothing is anchored on anyone else's framing.

```bash
# Technical / repo plan — Codex, grounded in the code:
codex exec --sandbox read-only "<request, verbatim> — produce an independent \
implementation plan: approach, files, sequencing, risks, milestones. \
Examine the repo as needed." < /dev/null

# Business / strategy / writing plan — ChatGPT INSTEAD of Codex:
~/.local/bin/chatgpt-plan -p "<request, verbatim> — produce an independent plan: \
positioning/approach, assumptions, priorities, first milestones, top risks, and \
the single most important thing to validate first."

# Always, for both plan types:
~/.local/bin/kimi-review -p "<request, verbatim> — produce an independent \
step-by-step plan: approach, assumptions, sequencing, risks. Read the repo as needed." < /dev/null

~/.local/bin/glm-review -p "<request, verbatim> — produce an independent plan: \
approach, assumptions, steps, risks; prefer the simplest/cheapest approach that meets the goal."
```

Two details that bite:

- **`< /dev/null` is required** whenever the prompt is passed as an argument (Codex, Kimi, GLM) — otherwise they stall waiting on stdin. `chatgpt-plan` accepts `-p` or a pipe.
- **Planning stays read-only.** Codex at `--sandbox workspace-write` will *implement* instead of propose. Kimi is read-only via disposable-worktree isolation; GLM via tool allowlist + external cwd; ChatGPT has no tools at all.

If the request depends on conversation context the others lack, prepend the minimum needed to make it standalone — and mark what you added.

### Step 2 — plan in parallel, don't idle

While the external voices run, the host forms its own full plan. It's free latency; use it.

### Step 3 — harvest (the editor step)

This is the part that's easy to do badly. **Do not concatenate the four plans into one document.** "Verbatim, grouped by reviewer" is the *review* gate's contract, not planning's.

1. **Steelman each plan first**, including the host's own. For every plan, state explicitly what it got right that the others missed. This step exists specifically to guard against editor bias — the failure mode is a host that quietly prefers its own plan and cherry-picks a token idea from each of the others.
2. **Harvest the best pieces** into one plan.
3. **Coherence pass.** The merged plan must hold together as one design, not read as a graft of locally-good parts pointing in different directions.
4. Present **one** edited plan.

### Step 4 — surface genuine forks

If the voices diverged on a *fundamental* approach — not a detail — present the fork: each option on one line, plus one sentence on the core tradeoff, and let the user pick. The user is the tiebreaker on real approach-forks, because only they know which goal actually matters.

Otherwise present the synthesized plan. Either way, the user approves before work starts. A notably rejected approach is worth recording in the commit body.

## Cost

Adaptive. A simple plan is often just the host. The panel convenes by need, calls run in parallel, so wall time is the slowest external voice — typically 1–3 minutes. Codex bills the OpenAI plan; ChatGPT rides the same subscription; Kimi the Kimi Code plan; GLM the z.ai plan. CodeRabbit isn't called at all.

## Scope — this is Trigger 1 only

Triggers 2 and 3 stay **symmetric**: every reviewer independently scrutinizes the same diff. At review time the value comes from uncorrelated passes over one target, not from divided labor. Don't import the harvest model into the review gates, and don't import the "verbatim, grouped by reviewer" model into planning.
