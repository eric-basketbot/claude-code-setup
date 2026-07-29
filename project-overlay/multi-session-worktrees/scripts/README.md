# Claude Code hooks

Hook scripts wired into the Claude Code harness via per-machine `.claude/settings.json` (which is gitignored).
The scripts themselves live here so they're version-controlled and travel with the repo.

## auto-worktree.sh — `SessionStart`

When two or more `claude --output-format stream-json` processes are running and the new session is starting in
the canonical checkout (`<repo>`), this hook auto-creates a fresh
worktree at `~/.agent-worktrees/wt-auto-<epoch>-<pid>` on a `wt/auto-…` branch and tells the model to `cd`
there before any git mutation. No-op when alone in the checkout, when already in a worktree, or when invoked
outside the repo.

The worktree base directory (`~/.agent-worktrees/` by default; `BB_WORKTREE_BASE` env override) is chosen
to survive macOS reboot — `/tmp/` gets wiped on every boot, which historically destroyed uncommitted work when
a session was interrupted by an unplanned restart.

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
            "command": "bash /Users/<you>/Downloads/<project>/scripts/claude-hooks/auto-worktree.sh",
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

`git worktree prune` is called at the top of every run, so removing a `~/.agent-worktrees/wt-auto-*` (or
legacy `/tmp/wt-auto-*`) directory by hand (`rm -rf`) is enough — the worktree registry self-heals on the next
session start.

## track-git-cwd.sh — `PreToolUse` (Bash matcher)

Logs every git mutation (`add` / `commit` / `cherry-pick` / `push` / `reset` / `rm` / `merge` / `rebase` /
`stash`) to `~/.claude/logs/myproject-git-cwd.jsonl` as JSON-Lines, with CWD and parallel-session count
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
        "command": "bash /Users/<you>/Downloads/<project>/scripts/claude-hooks/track-git-cwd.sh",
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

## Auto-PR-on-green — `cleanup-worktree.sh` State 2

When the SessionEnd / idle-reaper / daily-janitor calls `cleanup-worktree.sh` on a worktree with
clean tracked files but unpushed commits ("State 2: clean + unpushed"), the script now tries to
open a **draft PR** to `main` before queueing the branch for review:

1. Resolve "already a PR?" via `gh pr view <branch>`. If yes, reuse the URL.
2. Else `git push -u origin <branch>` and `gh pr create --draft --base main`.
3. On success, the queue line is appended with the PR URL in the trailing field.
4. On any failure (no network, no `gh` auth, push rejected), fall through to the plain queue
   path — work is never lost.

Why: the old behavior parked branches in `~/.claude/logs/myproject-review-queue.log` and let them
age out via the 3-day janitor. Auto-PRs turn "done but not shipped" into visible work with a
forcing function.

### Suppressing per-invocation

- `BB_AUTO_PR=0` env var → script skips the PR attempt and goes straight to the queue.
- `touch <worktree>/.no-auto-pr` → per-worktree marker, also skipped.

Either makes the cleanup behave like the pre-2026-05-18 version for that one branch.

### Review-queue log format

Now appends a sixth `|`-separated field (PR URL or empty). Legacy lines without the field are
still parsed correctly — `stale-shipping-digest.sh` does an on-demand `gh pr view` fallback when
the PR URL column is missing.

## stale-shipping-digest.sh — daily 09:00 launchd job

Surfaces "done but not shipped" drift once a day. Sources:

1. Entries in `~/.claude/logs/myproject-review-queue.log` older than `BB_DIGEST_MAX_AGE_HOURS`
   (default 24h).
2. Live `wt/auto-*` worktrees from the registry whose last commit is older than the threshold
   and is ahead of `main`.

For each stale branch the digest captures: branch · age · ahead-of-main · last-commit subject ·
PR URL (resolved on demand via `gh pr view`).

Output:

- Appended to `~/.claude/logs/myproject-stale-shipping-digest.log` every day (heartbeat — runs
  whether or not anything is stale).
- Telegram message sent **only** when stale_count > 0, so quiet days stay silent.

### Telegram setup (one-time)

The script looks for creds in this order:

1. `$TELEGRAM_BOT_TOKEN` / `$TELEGRAM_CHAT_ID` env vars.
2. `~/.config/myproject/telegram.env` (or `$BB_DIGEST_TELEGRAM_ENV` override) — file with two
   `KEY=value` lines.
3. None → log-only, no Telegram (script exits 0).

VPS already has these in `/opt/<project>/.env`. To copy to the Mac once:

```bash
mkdir -p ~/.config/myproject
ssh <user>@<host> 'grep -E "^(TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID)=" /opt/<project>/.env' \
  > ~/.config/myproject/telegram.env
chmod 600 ~/.config/myproject/telegram.env
```

### Install (one-time)

```bash
cp scripts/claude-hooks/com.myproject.stale-shipping-digest.plist \
   ~/Library/LaunchAgents/com.myproject.stale-shipping-digest.plist
launchctl unload ~/Library/LaunchAgents/com.myproject.stale-shipping-digest.plist 2>/dev/null
launchctl load   ~/Library/LaunchAgents/com.myproject.stale-shipping-digest.plist
```

Smoke-test by lowering the threshold:

```bash
BB_DIGEST_MAX_AGE_HOURS=1 bash scripts/claude-hooks/stale-shipping-digest.sh
tail -30 ~/.claude/logs/myproject-stale-shipping-digest.log
```
