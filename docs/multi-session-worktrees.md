# Multi-session worktree harness

When to install: you run two or more Claude Code sessions against the same repo at once and want each to work on its own branch without stepping on the others.

## The problem

Default Claude Code: you `cd /path/to/repo`, run `claude`, and the model edits files directly in your canonical working tree. Open a second session in another terminal and now both sessions are mutating the same working directory. The first session's `git checkout` confuses the second. A `git reset --hard` in one wipes uncommitted work in the other. Branches get tangled.

Solutions exist (manually create worktrees per session, use VS Code workspaces, etc.) but none are enforced — it's all opt-in discipline.

## What this harness enforces

1. **SessionStart hook**: every Claude session in the canonical repo gets auto-redirected to a fresh git worktree at `~/.agent-worktrees/wt-auto-<date>-<pid>` on branch `wt/auto-<id>`. Build dependencies (`node_modules`, build output, `.env` files) are symlinked from canonical so the worktree builds and tests without reinstalling. Override the base with `WORKTREE_BASE`.

   🔴 **The base must not be under `/tmp/`.** It originally was, and macOS wipes `/tmp/` on reboot — that wipe destroyed uncommitted work in a live incident. The scripts still *recognize* legacy `/tmp/wt-auto-*` paths so in-flight sessions can be cleaned up, but nothing new is created there. If you adapt this harness, keep the base somewhere reboot-survivable.

2. **PreToolUse hook on `git`**: blocks `git add` / `commit` / `cherry-pick` / `reset --hard` / `restore` / `rebase` / `merge` / `stash` / `rm` in the canonical working tree with exit code 2 — but ONLY when ≥2 Claude sessions are alive. Solo sessions get a soft warning, not a hard block. The error message names the exact worktree path the session should `cd` into (read from a per-host registry).

3. **PreToolUse hook on `git push`**: blocks pushes to shared branches (`main`, deploy targets) when local HEAD is behind remote, and blocks all `--force` / `--force-with-lease` to those branches.

4. **SessionEnd hook**: 4-state cleanup machine:
   - Clean + merged → delete the worktree.
   - Clean + unpushed commits → preserve the worktree, log to review queue, branch stays alive so you can pick it up later.
   - Dirty (uncommitted changes) → auto-`git stash` with a recoverable message, then delete the worktree.
   - Untracked-only files → move them to `~/.claude/logs/<slug>-orphan-files/<branch>-<iso>/` so they're not lost.

5. **Hourly idle reaper (launchd)**: catches sessions that crashed without firing SessionEnd. Reaps orphaned worktrees + stale registry entries.

6. **Daily janitor (launchd, 04:00 local)**: prunes anything older than 3 days and deletes merged `wt/auto-*` branches.

7. **Slash commands**:
   - `/wt-sessions` — print active sessions, file overlap between them, review queue, stash backlog, weekly summary.
   - `/wt <slug>` — manual long-lived worktree at `../<project>-<slug>` for named feature work.

## Install

```bash
./project-overlay/multi-session-worktrees/install-in-project.sh /path/to/your/repo
```

What it does:

1. Copies the 12 hook scripts into `<your-repo>/scripts/claude-hooks/`.
2. Prints a `CLAUDE.md` fragment for you to paste into `<your-repo>/CLAUDE.md`.
3. Wires the SessionStart, PreToolUse, SessionEnd hooks into `<your-repo>/.claude/settings.local.json` (per-project settings — does NOT touch user-level `~/.claude/settings.json`).

Optional:

```bash
./project-overlay/multi-session-worktrees/install-in-project.sh /path/to/your/repo --launchd
```

Additionally installs the hourly idle-reaper + daily-janitor launchd jobs (macOS only).

Re-runnable. `--dry-run` previews. `--uninstall` reverses.

### 🔴 macOS TCC silently breaks the launchd safety net

If your repo lives under a TCC-protected directory — `~/Downloads`, `~/Documents`, `~/Desktop` — macOS blocks launchd-spawned `bash` from reading scripts there. Both reapers fail silently: the jobs are loaded, they "run", and they do nothing.

The fix is a one-time **Full Disk Access** grant for `/bin/bash` (System Settings → Privacy & Security → Full Disk Access). Or move the repo somewhere unprotected, e.g. `~/src/`.

The SessionEnd hook is unaffected — it runs as a child of your `claude` process, which already has TCC permission. So the *common* path keeps working and only the crash-recovery path is dead, which is exactly the shape of failure you don't notice until you need it. Verify after install:

```bash
launchctl list | grep -i worktree      # loaded?
tail ~/.claude/logs/*idle-reaper*.log   # actually doing anything?
```

## Restart any open Claude sessions

The auto-worktree hook only fires on session start. After install, existing sessions won't see it until they restart.

## Escape hatches

- `STAY_IN_CANONICAL=1 claude` — skip auto-worktree for read-only research sessions. The git-mutation block still warns.
- Run `git push --force` etc. yourself in a terminal **outside Claude** when you genuinely need to bypass the push guard. The hook only affects Claude Code's Bash invocations.

## 🔴 Auto-worktrees branch from a STALE local main

The SessionStart hook does not fetch before creating the worktree. If your canonical checkout's local `main` is behind `origin/main`, every session that day starts from stale code — and you will diagnose bugs that were fixed upstream a week ago, or open a PR whose diff includes changes that already landed.

Check before investigating anything or opening a PR:

```bash
git rev-list --count main..origin/main    # must be 0
```

(The version of the hook shipped here prints a warning and branches from the remote when it detects this, but confirm rather than assume — an older copy may not.)

## Recovery

- **Stashes from auto-cleanup**: live in canonical's stash list with messages like `auto-cleanup wt/<branch> <iso>`. `git stash list` then `git stash show -p stash@{N}`.
- **Untracked files from cleanup**: under `~/.claude/logs/<slug>-orphan-files/<branch>-<iso>/`. `cp -r` back into place.
- **Branches with unpushed commits**: stay in `~/.claude/logs/<slug>-review-queue.log`. The worktree is preserved so you can `cd` in, push, and clean up manually.
- **Polluted canonical working tree** (rare): `bash scripts/claude-hooks/triage-canonical-backlog.sh` is idempotent and tries to triage anything stuck in canonical.

## When NOT to install this

- Solo Claude session always, only ever one at a time → the overhead isn't worth it. Solo sessions get a soft warning anyway.
- Your repo has unusual native-modules / Docker-in-CI / build-from-source setups where symlinking `node_modules` won't work. The harness assumes a fairly standard JS/Python project layout; adapt the symlink list in `auto-worktree.sh` if needed.
- Windows / non-macOS hosts. The launchd jobs are macOS-specific. The shell hooks themselves work on Linux but you'll need systemd timers (or cron) instead of launchd.

## Customization points

Inside `scripts/claude-hooks/_lib.sh`:

- `CANONICAL`: auto-detected from script location; override with `CANONICAL=/path source _lib.sh`.
- `PROJECT_SLUG`: derived from `$(basename "$CANONICAL")`; override the same way.
- `REGISTRY_FILE`, `REVIEW_QUEUE_LOG`, etc.: derived from `PROJECT_SLUG`.

Inside `auto-worktree.sh`:

- The symlink list (`node_modules`, `.env`, `dist/`, etc.) — adjust for your stack.

Inside `check-remote-push.sh`:

- The protected-branch list (`main`, `vps`, `vps-staging`) — change to match your deploy branches.
