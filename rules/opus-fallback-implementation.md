# Opus-Fallback Implementation Protocol (Claude orchestrates, Codex implements)

Dormant while the Claude session runs on Fable (normal: Claude plans AND implements).
It activates when the Claude session is running on a fallback model — normally
**Opus** after usage limits; the same protocol applies if the harness ever falls
back to Sonnet or Haiku. Activation signals, in order of authority: (1) the user
says so ("you're on Opus — delegate"); (2) the session's own context identifies a
non-Fable model. If the signal is ambiguous, confirm with the user before the
first dispatch. Planning already happened on Fable (or happens on the fallback
model with the full Trigger-1 panel); this protocol governs who writes the code.

## Division of labor while on a fallback model

- **Claude keeps**: orchestration, task decomposition, ALL git operations
  (branch/commit/push/PR), review-gate dispatch (Triggers 1–3), and memory-KB updates.
- **The implementer engine takes** (Codex `gpt-5.6-sol`, or the ladder below when
  it's capped): implementation of non-trivial work (same non-trivial definition
  as the adversarial-review gates). It edits files in the session worktree, runs
  builds/tests, and returns a summary.
- **Trivial edits**: Claude does them itself — don't burn Codex quota.

## Dispatch (Claude → Codex)

Write the task text to a file first, then use the wrapper — it validates the
worktree, injects the dispatch sentinel, passes the task safely, snapshots git
state, and applies the retry ladder:

```bash
~/.claude/scripts/codex-implementation-fallback.sh --repo <session-worktree> --task-file <task.txt>
```

- **Never paste task text inline into a shell command** — backticks and `$()` in
  task text would execute in the outer shell before Codex ever runs. The wrapper
  reads the file and passes it as a single argument with stdin from `/dev/null`
  (heredoc-to-stdin hangs codex).
- Task text must include: the goal and acceptance criteria, relevant file paths,
  and any must-not-change constraints. The wrapper prepends the
  `[OPUS-FALLBACK DISPATCH]` sentinel and the no-git instructions automatically.
- The wrapper refuses the canonical checkout (exit 4), retries once on a usage
  limit (`-m gpt-5.5`) or exit 137 ONLY if the workspace is untouched, refuses to
  retry over partial edits (exit 5), and fails loudly (exit 3) if a commit or
  branch switch appears — it never auto-resets.
- After dispatch, review the wrapper's post-report (`git status --porcelain`
  delta, model used) and inspect the diff before anything else happens.
- Worktree symlinks: `node_modules/`, `dist/`, `client/dist/`, `.next/` are
  symlinks into canonical — don't dispatch tasks whose goal is writing those paths.
- There is NO raw fallback: `--sandbox workspace-write` is permitted ONLY through
  this wrapper (permission matrix in the shared contract). If the wrapper is
  missing, the protocol fails closed — Claude implements itself and flags the
  missing wrapper (the ai-config audit enforces its existence).

## Codex, when dispatched as implementer

This section applies ONLY when your task prompt begins with
`[OPUS-FALLBACK DISPATCH]` — i.e., a Claude session dispatched you through the
wrapper. **Interactive Codex sessions: ignore this section and use git normally.**

When dispatched: you are implementing on Claude's behalf inside the current
worktree. Edit files and run builds/tests freely within the workspace. Do NOT run
`git commit`, `git push`, or any branch/remote/stash operation — the orchestrator
owns git (repo hooks also block canonical mutation fail-shut, and the wrapper
fails the dispatch if HEAD or the branch moves). End your reply with a summary of
changes and the list of files touched.

## Engine ladder and failure handling

The wrapper implements this ladder (facts also in the shared contract
`multi-ai-harness.md`, contract-id: multi-ai-harness-v2); stated here so both
hosts know the policy:

1. **Codex `gpt-5.6-sol`** — the default implementer.
2. **Kimi managed (K-series)** — when sol hits its usage limit (user directive
   2026-07-18: Kimi outranks `gpt-5.5`; expected to be exceedingly rare). This
   uses the subscription and Kimi's native Extra Usage. Bare headless `kimi` in
   the worktree — no OS sandbox, contained by the sentinel constraints + the
   wrapper's git guard + worktree isolation.
3. **Kimi Open Platform API (`kimi-k3`)** — only after an exact managed-quota
   exhaustion response. The key is read from macOS Keychain service
   `ai-config.kimi.MOONSHOT_API_KEY` and injected at runtime; the wrapper clearly
   announces the paid billing source. Generic errors and rate limits do not bill.
4. **Codex `-m gpt-5.5`** — when Kimi is unavailable (unauthenticated `LLM not
   set`, missing binary, or error), the paid key is absent, or the API retry fails.
5. **Claude implements itself** and reports the full degradation to the user.

- Every rung change requires an UNTOUCHED workspace; partial edits stop the
  ladder (wrapper exit 5) — never rerun the original task over them
  (duplication risk). Claude inspects the diff and either completes the work
  itself or dispatches a continuation task grounded in the partial diff.
- **Exit 137**: transient host memory pressure — one retry on the same engine,
  same untouched-workspace guard.
- The wrapper's post-report names the engine that produced the diff — the
  review gates need it (see below). The REVIEW waterfall (`codex-reviewer`:
  sol → `gpt-5.5`) is separate and unchanged.

## Review gates for engine-authored diffs

Triggers 2/3 still run in full, but the review by whichever engine IMPLEMENTED
the diff (per the wrapper's engine report) is **advisory-only**: excluded from
convergence counts and the reviewer-failure math. Quorum is recomputed from the
remaining eligible panel — worked table in the shared contract
(`multi-ai-harness.md` § Authored-diff advisory rule). Claude did not author the
diff, so its review is fully independent here; caps are time-boxed, so Codex can
usually review a Kimi-authored diff even if it was capped at implementation
time. Mixed authorship counts as authored: if the engine wrote any material
portion, its review of the whole diff is advisory. Record "authored by:
<engine>" in any handoff or session summary so the advisory rule survives
context compaction.

## Sandbox discipline (never weaken)

`--sandbox workspace-write` is ONLY for this dispatched implementer role. Planning
dispatches stay `--sandbox read-only`; review stays `codex exec review` and the
read-only wrappers. Never use `danger-full-access` or any bypass flag.
