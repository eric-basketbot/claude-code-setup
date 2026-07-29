# Implementation fallback — who writes the code when the host degrades

Rule: [`../rules/opus-fallback-implementation.md`](../rules/opus-fallback-implementation.md).
Wrapper: [`../scripts/codex-implementation-fallback.sh`](../scripts/codex-implementation-fallback.sh).

## The problem

Your primary model has a usage limit. When you hit it, the harness silently drops you to a weaker model — and the session keeps going as if nothing happened. You now have a less capable model writing production code, at exactly the moment you're least likely to notice, because the conversation reads the same.

The naive responses are both bad: stop working until the limit resets, or let the weaker model implement and hope.

## The response

Split the roles. When the host is running on a fallback model, it **keeps orchestration and gives away implementation**:

| Stays with the host | Goes to the implementer engine |
|---|---|
| Task decomposition | Writing the code |
| **All git operations** (branch, commit, push, PR) | Running builds and tests in the workspace |
| Review-gate dispatch (T1/T2/T3) | Returning a summary of what changed |
| Memory / knowledge-base updates | |
| Trivial edits (don't burn quota) | |

This works because orchestration degrades gracefully under a weaker model and implementation doesn't. A weaker model can still decide *what* to do and hold the process; the risk concentrates in *how* the code gets written.

The protocol is dormant while the session runs on the primary model. It activates when the user says so, or when the session's own context identifies a fallback model. If the signal is ambiguous, confirm before the first dispatch.

## The engine ladder

1. **Codex `gpt-5.6-sol`** — the default implementer.
2. **Kimi managed (K-series)** — when Codex hits its usage limit. Uses the subscription and its native Extra Usage.
3. **Kimi paid Open Platform API (`kimi-k3`)** — *only* after an exact managed-quota exhaustion response, with the key injected at runtime from the macOS Keychain. The wrapper announces the paid billing source out loud.
4. **Codex `-m gpt-5.5`** — when Kimi is unavailable or its paid retry fails.
5. **The orchestrator implements itself** and reports the full degradation to the user.

Ordinary network errors, rate limits, and tool failures **never** authorize the paid rung. Only an explicit quota-exhaustion response does.

## The dispatch contract

```bash
# write the task to a file FIRST, then:
~/.claude/scripts/codex-implementation-fallback.sh \
  --repo <session-worktree> --task-file <task.txt>
```

**Never paste task text inline into a shell command.** Backticks and `$()` inside task text would execute in the *outer* shell before the engine ever sees them. The wrapper reads the file and passes it as a single argv with stdin from `/dev/null` (heredoc-to-stdin hangs Codex).

The task text must carry: the goal and acceptance criteria, the relevant file paths, and any must-not-change constraints. The wrapper prepends the `[OPUS-FALLBACK DISPATCH]` sentinel and the no-git instructions itself.

### Five enforced invariants

1. **Worktree only.** Refuses the canonical checkout outright (exit 4).
2. **Safe prompt passing.** From `--task-file`, one argv, stdin from `/dev/null`.
3. **Sentinel.** Prepends the dispatch marker plus role constraints, so the engine knows it's acting on someone else's behalf.
4. **Git-state guard.** Snapshots HEAD and branch before and after. A commit or branch switch by *any* engine is exit 3 — loud, and **never auto-reset**. The orchestrator owns git; an engine that touched it is a bug you need to see, not damage to silently repair.
5. **Engine report.** Prints which engine actually produced the diff. The review gates need this to apply the advisory rule.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 2 | usage error |
| 3 | git-state violation (a commit or branch switch appeared) |
| 4 | refused — canonical checkout, not a worktree |
| 5 | partial edits present, ladder stopped |
| 6 | all engines exhausted; orchestrator implements and reports |
| other | the final engine's own exit code |

## The partial-edit rule

**Every rung change requires an untouched workspace.** If an engine died halfway through and left edits behind, the ladder stops with exit 5 and the wrapper refuses to retry.

This is the single most important safety property in the whole protocol. Re-running the original task over a partial diff is how you get duplicated work — a second half-implementation layered on the first, with no clean way to tell them apart afterwards. When you hit exit 5, inspect the diff and either finish the work yourself or dispatch a *continuation* task explicitly grounded in the partial diff.

Exit 137 (transient host memory pressure) gets one retry on the same engine, under the same untouched-workspace guard.

## Sandbox discipline

`--sandbox workspace-write` is permitted **only** through this wrapper, only for the dispatched implementer role. Planning dispatches stay `--sandbox read-only`. Review stays on the read-only wrappers. Never `danger-full-access`, never any bypass flag.

There is no raw fallback path. If the wrapper is missing, the protocol **fails closed** — the orchestrator implements it itself and flags the missing wrapper. (The config audit enforces that the wrapper exists and is executable, precisely so this can't silently degrade.)

One accepted residual risk, documented rather than hidden: the Kimi rung runs bare headless `kimi` with **no OS sandbox**. Containment is the sentinel constraints, the wrapper's git guard, and worktree isolation. A misbehaving engine could write outside the worktree. The engine is treated as trusted-but-fallible; a malicious engine is out of the threat model; and the rung is rare.

⚠️ In a worktree, `node_modules/`, `dist/`, and similar are typically **symlinks into canonical**. Never dispatch a task whose goal is writing those paths, and the Kimi rung's prompt says so explicitly — it has no sandbox to stop it.

## The engine that wrote it reviews advisory-only

Whichever engine implemented the diff still runs at T2 and T3, but its review is labeled advisory (`## Codex Review (advisory — authored this diff)`) and excluded from convergence counting and the reviewer-failure math. Mixed authorship counts as authored.

The panel is arguably *stronger* than usual under this protocol, because the host — normally the author — didn't write the diff and is therefore fully independent for once.

Quorum recomputes from the remaining eligible panel; the worked table is in [`review-panel.md`](review-panel.md#when-the-reviewer-wrote-the-code). Record `authored by: <engine>` in handoffs so the rule survives context compaction.
