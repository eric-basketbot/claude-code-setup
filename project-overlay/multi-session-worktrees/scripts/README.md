# Claude Code hooks

Hook scripts wired into the Claude Code harness via per-machine `.claude/settings.json` (which is gitignored).
The scripts themselves live here so they're version-controlled and travel with the repo.

## auto-worktree.sh — `SessionStart`

When two or more `claude --output-format stream-json` processes are running and the new session is starting in
the canonical checkout (`<your-project-root>`), this hook auto-creates a fresh
worktree at `/tmp/${PROJECT_SLUG}-auto-<epoch>-<pid>` on a `wt/auto-…` branch and tells the model to `cd` there before any
git mutation. No-op when alone in the checkout, when already in a worktree, or when invoked outside the repo.

Why: with multiple sessions sharing one `.git/index`, a `git add` in session A becomes part of session B's
next `git commit`. Fixed procedurally — each session gets its own index via worktree.

### One-time per-machine setup

Add a `SessionStart` block to `.claude/settings.json` in the canonical checkout:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /Users/<you>/Downloads/<your-project>/scripts/claude-hooks/auto-worktree.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

Subsequent claude sessions will run the hook automatically.

### Cleanup

`git worktree prune` is called at the top of every run, so removing a `/tmp/${PROJECT_SLUG}-auto-*` directory by hand
(`rm -rf`) is enough — the worktree registry self-heals on the next session start.

## track-git-cwd.sh — `PreToolUse` (Bash matcher)

Logs every git mutation (`add` / `commit` / `cherry-pick` / `push` / `reset` / `rm` / `merge` / `rebase` /
`stash`) to `~/.claude/logs/${PROJECT_SLUG}-git-cwd.jsonl` as JSON-Lines, with CWD and parallel-session count
captured at execution time. When a "should-be-in-worktree" condition is detected (canonical checkout +
≥2 active claude sessions), the hook also emits a one-line `POLICY_REMINDER` on stdout for the model to
see — gentle reinforcement, not a hard block.

Read-only on the filesystem and the command. Never blocks.

### One-time per-machine setup

Add to the `hooks` block in `.claude/settings.json` alongside the SessionStart hook:

```json
"PreToolUse": [
  {
    "matcher": "Bash",
    "hooks": [
      {
        "type": "command",
        "command": "bash /Users/<you>/Downloads/<your-project>/scripts/claude-hooks/track-git-cwd.sh",
        "timeout": 5
      }
    ]
  }
]
```

### Reading the log

```bash
# All-time compliance rate + last 5 violations
scripts/claude-hooks/git-cwd-report.sh

# Today only
scripts/claude-hooks/git-cwd-report.sh --today

# Last N raw events
scripts/claude-hooks/git-cwd-report.sh --tail 20
```

### When to escalate to enforcement

If `--today` shows a meaningful violation rate after a few days, swap the gentle stdout reminder for a
hard `exit 2` in track-git-cwd.sh — that turns the hook into a blocking PreToolUse that aborts the
offending git command. Track first, escalate only if the directive isn't enough.
