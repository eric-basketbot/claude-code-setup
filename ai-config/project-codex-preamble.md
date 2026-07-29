## Parallel sessions — Codex never edits canonical

Codex sessions must not edit the canonical checkout at
`$HOME/Downloads/<project>`. Use a dedicated worktree under
`~/.myproject-worktrees/` for every change, even when only one session appears
active. Read-only inspection of canonical is allowed.

Before editing, create or enter an isolated worktree from the intended baseline.
Run all file edits, staging, commits, rebases, merges, and stashes there. Never
share canonical's `.git/index` with another Claude or Codex session.

Use `git worktree list` to confirm the current location. If a requested action
would mutate canonical, stop and move the work into a dedicated worktree first.
